// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ISlashing, IBFTMessage} from "./ISlashing.sol";
import {System} from "../../../common/System/System.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IInspector} from "../../../HydraChain/modules/Inspector/IInspector.sol";
import {IHydraStaking} from "../../IHydraStaking.sol";
import {IBLS} from "../../../BLS/IBLS.sol";

// Extend with interface for pubkey access
interface IInspectorWithPubkey {
    function getValidatorPubkey(address validator) external view returns (uint256[4] memory);
}

/**
 * @title Slashing
 * @notice Handles all slashing logic for validators who commit double-signing
 * @dev This contract is responsible for:
 *      - Validating double-signing evidence
 *      - Verifying BLS signatures
 *      - Managing slashed funds
 *      - Storing evidence for auditing
 *      - Coordinating with Inspector for validator banning
 */
contract Slashing is ISlashing, System, Initializable, ReentrancyGuardUpgradeable {
    // _______________ Constants _______________

    /// @notice Lock period for slashed funds (30 days)
    uint256 public constant SLASH_LOCK_PERIOD = 30 days;

    /// @notice Maximum length for slashing reason
    uint256 public constant MAX_REASON_LENGTH = 100;

    // _______________ State Variables _______________

    /// @notice BLS contract for signature verification
    IBLS public bls;

    /// @notice Reference to the HydraChain contract (Inspector module)
    address public hydraChainContract;

    /// @notice Reference to the HydraStaking contract
    IHydraStaking public hydraStakingContract;

    /// @notice Mapping to track if a validator has been slashed (prevents double slashing)
    mapping(address => bool) private _hasBeenSlashed;

    /// @notice Mapping to track slashed amounts per validator
    mapping(address => uint256) public slashedAmounts;

    /// @notice Mapping to track locked slashed funds per validator
    mapping(address => uint256) public lockedSlashedAmount;

    /// @notice Mapping to track unlock timestamp for slashed funds per validator
    mapping(address => uint256) public lockedSlashedUnlockTime;

    /// @notice Mapping to store evidence hash for each slashed validator (for auditing)
    mapping(address => bytes32) public slashingEvidenceHash;

    // _______________ Custom Errors _______________

    error InvalidValidatorAddress();
    error ValidatorAlreadySlashed();
    error ReasonTooLong();
    error NoLockedSlashedFunds();
    error FundsStillLocked();
    error BurnFailed();
    error EvidenceMismatch(string detail);
    error BLSNotSet();

    // _______________ Events _______________

    /// @notice Emitted when double-signing evidence is validated and stored
    event DoubleSignEvidence(
        address indexed validator,
        bytes32 evidenceHash,
        uint64 height,
        uint64 round,
        bytes32 msg1Hash,
        bytes32 msg2Hash
    );

    /// @notice Emitted when slashed funds are burned
    event SlashedFundsBurned(address indexed validator, uint256 amount);

    // _______________ Initializer _______________

    /**
     * @notice Initializer for upgradeable pattern
     * @param hydraChainAddr Address of the HydraChain contract
     * @param hydraStakingAddr Address of the HydraStaking contract
     */
    function initialize(
        address hydraChainAddr,
        address hydraStakingAddr
    ) external initializer onlySystemCall {
        __ReentrancyGuard_init();
        __Slashing_init(hydraChainAddr, hydraStakingAddr);
    }

    // solhint-disable-next-line func-name-mixedcase
    function __Slashing_init(
        address hydraChainAddr,
        address hydraStakingAddr
    ) internal onlyInitializing {
        hydraChainContract = hydraChainAddr;
        hydraStakingContract = IHydraStaking(hydraStakingAddr);
    }

    // _______________ External Functions _______________

    /**
     * @notice Set or update BLS contract address (for upgradeable pattern)
     * @param blsAddr Address of the BLS contract
     */
    function setBLSAddress(address blsAddr) external onlySystemCall {
        bls = IBLS(blsAddr);
    }

    /**
     * @notice Called by the system to slash a validator for double-signing
     * @dev Validates evidence, verifies BLS signatures, and coordinates slashing
     * @param validator Address of the validator to be slashed
     * @param msg1 First conflicting IBFT message
     * @param msg2 Second conflicting IBFT message
     * @param reason Reason for slashing (string)
     */
    function slashValidator(
        address validator,
        IBFTMessage calldata msg1,
        IBFTMessage calldata msg2,
        string calldata reason
    ) external onlySystemCall nonReentrant {
        // Validation checks
        if (validator == address(0)) revert InvalidValidatorAddress();
        if (_hasBeenSlashed[validator]) revert ValidatorAlreadySlashed();
        if (bytes(reason).length > MAX_REASON_LENGTH) revert ReasonTooLong();
        if (address(bls) == address(0)) revert BLSNotSet();

        // Validate evidence structure
        _validateEvidence(validator, msg1, msg2);

        // Verify BLS signatures
        _verifyBLSSignatures(validator, msg1, msg2);

        // Store evidence for auditing
        bytes32 evidenceHash = keccak256(abi.encode(msg1, msg2));
        slashingEvidenceHash[validator] = evidenceHash;

        // Mark as slashed to prevent double slashing
        _hasBeenSlashed[validator] = true;

        // Get validator's stake before slashing
        uint256 slashAmount = hydraStakingContract.stakeOf(validator);
        require(slashAmount > 0, "Slashing: No stake to slash");

        // Record slashed amount
        slashedAmounts[validator] = slashAmount;

        // Unstake from HydraStaking (100% penalty for double signing)
        hydraStakingContract.unstakeFor(validator, slashAmount);

        // Burn the slashed funds immediately (no lock period)
        _burnSlashedFunds(slashAmount);

        // Emit detailed evidence event
        emit DoubleSignEvidence(
            validator,
            evidenceHash,
            msg1.height,
            msg1.round,
            keccak256(msg1.data),
            keccak256(msg2.data)
        );

        // Notify Inspector to ban the validator
        IInspector(hydraChainContract).onValidatorSlashed(validator, reason);

        // Emit slashing event
        emit ValidatorSlashed(validator, reason);
    }

    /**
     * @notice Check if a validator has been slashed
     * @param validator Address of the validator
     * @return True if the validator has been slashed
     */
    function hasBeenSlashed(address validator) external view returns (bool) {
        return _hasBeenSlashed[validator];
    }

    /**
     * @notice Get the slashed amount for a validator
     * @param validator Address of the validator
     * @return The total amount slashed
     */
    function getSlashedAmount(address validator) external view returns (uint256) {
        return slashedAmounts[validator];
    }

    /**
     * @notice Get the evidence hash for a slashed validator
     * @param validator Address of the validator
     * @return The stored evidence hash
     */
    function getEvidenceHash(address validator) external view returns (bytes32) {
        return slashingEvidenceHash[validator];
    }

    // _______________ Internal Functions _______________

    /**
     * @notice Validate the double-signing evidence structure
     * @param validator Address of the validator
     * @param msg1 First IBFT message
     * @param msg2 Second IBFT message
     */
    function _validateEvidence(
        address validator,
        IBFTMessage calldata msg1,
        IBFTMessage calldata msg2
    ) internal pure {
        // Both messages must be from the validator
        if (msg1.from != validator || msg2.from != validator) {
            revert EvidenceMismatch("Evidence: from != validator");
        }

        // Messages must be from the same height
        if (msg1.height != msg2.height) {
            revert EvidenceMismatch("Evidence: height mismatch");
        }

        // Messages must be from the same round
        if (msg1.round != msg2.round) {
            revert EvidenceMismatch("Evidence: round mismatch");
        }

        // Messages must be of the same type
        if (msg1.msgType != msg2.msgType) {
            revert EvidenceMismatch("Evidence: type mismatch");
        }

        // Messages must have different data (this is the conflicting part)
        if (keccak256(msg1.data) == keccak256(msg2.data)) {
            revert EvidenceMismatch("Evidence: identical message data");
        }

        // Signatures must be different
        if (keccak256(msg1.signature) == keccak256(msg2.signature)) {
            revert EvidenceMismatch("Evidence: identical signatures");
        }
    }

    /**
     * @notice Verify BLS signatures for both messages
     * @param validator Address of the validator
     * @param msg1 First IBFT message
     * @param msg2 Second IBFT message
     */
    function _verifyBLSSignatures(
        address validator,
        IBFTMessage calldata msg1,
        IBFTMessage calldata msg2
    ) internal view {
        // Get validator's public key from Inspector
        uint256[4] memory pubkey = IInspectorWithPubkey(hydraChainContract).getValidatorPubkey(validator);

        // Decode BLS signatures from bytes
        uint256[2] memory sig1 = abi.decode(msg1.signature, (uint256[2]));
        uint256[2] memory sig2 = abi.decode(msg2.signature, (uint256[2]));

        // Hash the message data for BLS verification
        bytes32 msg1DataHash = keccak256(msg1.data);
        bytes32 msg2DataHash = keccak256(msg2.data);
        uint256[2] memory msg1ForBLS = [uint256(msg1DataHash), 0];
        uint256[2] memory msg2ForBLS = [uint256(msg2DataHash), 0];

        // Verify BLS signatures
        (bool ok1, ) = bls.verifySingle(sig1, pubkey, msg1ForBLS);
        require(ok1, "Evidence: msg1 signature invalid");

        (bool ok2, ) = bls.verifySingle(sig2, pubkey, msg2ForBLS);
        require(ok2, "Evidence: msg2 signature invalid");
    }

    /**
     * @notice Burn slashed funds by sending to address(0)
     * @param amount Amount to burn
     */
    function _burnSlashedFunds(uint256 amount) internal {
        if (amount > 0) {
            // Send to address(0) to effectively burn the funds
            (bool success, ) = address(0).call{value: amount}("");
            if (!success) revert BurnFailed();

            emit SlashedFundsBurned(address(0), amount);
        }
    }

    // _______________ Gap for Upgradeability _______________

    // slither-disable-next-line unused-state,naming-convention
    uint256[50] private __gap;
}
