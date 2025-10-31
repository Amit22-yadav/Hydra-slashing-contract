// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ISlashing, IBFTMessage} from "./ISlashing.sol";
import {System} from "../../../common/System/System.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IInspector} from "../../../HydraChain/modules/Inspector/IInspector.sol";
import {IBLS} from "../../../BLS/IBLS.sol";

// Extend with interface for pubkey access
interface IInspectorWithPubkey {
    function getValidatorPubkey(address validator) external view returns (uint256[4] memory);
}

/**
 * @title Slashing
 * @notice Validates double-signing evidence and triggers the Inspector's ban mechanism
 * @dev This contract is a thin validation layer that reuses Inspector's existing
 *      penalizeStaker + ban infrastructure to minimize code changes and bug risk.
 *
 *      Design Philosophy (per client requirements):
 *      - Reuse existing Inspector + PenalizedStakeDistribution pattern
 *      - Minimize modifications to existing core contracts
 *      - Evidence validation only - delegate execution to Inspector
 *      - Configurable penalty percentage (not hardcoded 100%)
 *      - Protection against mass slashing events
 */
contract Slashing is ISlashing, System, Initializable {
    // _______________ Constants & Configuration _______________

    /// @notice Maximum penalty percentage (in basis points, 10000 = 100%)
    uint256 public constant MAX_PENALTY_PERCENTAGE = 10000; // 100%

    /// @notice Default penalty percentage for double signing (in basis points)
    /// @dev Can be updated by governance. Start conservatively per client suggestion.
    uint256 public doubleSignPenaltyPercentage;

    /// @notice Maximum validators that can be slashed in a single block
    /// @dev Protection against mass slashing bugs that could harm decentralization
    uint256 public maxSlashingsPerBlock;

    /// @notice Tracks slashings per block for protection
    mapping(uint256 => uint256) public slashingsInBlock;

    // _______________ State Variables _______________

    /// @notice BLS contract for signature verification
    IBLS public bls;

    /// @notice Reference to the HydraChain contract (Inspector module)
    address public hydraChainContract;

    /// @notice Mapping to store evidence hash for each slashed validator (for auditing)
    mapping(address => bytes32) public slashingEvidenceHash;

    /// @notice Mapping to track if a validator has been slashed (prevents double slashing)
    mapping(address => bool) private _hasBeenSlashed;

    // _______________ Custom Errors _______________

    error InvalidValidatorAddress();
    error ValidatorAlreadySlashed();
    error EvidenceMismatch(string detail);
    error BLSNotSet();
    error MaxSlashingsExceeded();
    error InvalidPenaltyPercentage();

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

    /// @notice Emitted when penalty percentage is updated
    event PenaltyPercentageUpdated(uint256 oldPercentage, uint256 newPercentage);

    /// @notice Emitted when max slashings per block is updated
    event MaxSlashingsPerBlockUpdated(uint256 oldMax, uint256 newMax);

    // _______________ Initializer _______________

    /**
     * @notice Initializer for upgradeable pattern
     * @param hydraChainAddr Address of the HydraChain contract
     * @param initialPenaltyPercentage Initial penalty percentage (in basis points, 0-10000)
     * @param initialMaxSlashingsPerBlock Initial max slashings per block
     */
    function initialize(
        address hydraChainAddr,
        uint256 initialPenaltyPercentage,
        uint256 initialMaxSlashingsPerBlock
    ) external initializer onlySystemCall {
        require(initialPenaltyPercentage <= MAX_PENALTY_PERCENTAGE, "Penalty > 100%");

        hydraChainContract = hydraChainAddr;
        doubleSignPenaltyPercentage = initialPenaltyPercentage;
        maxSlashingsPerBlock = initialMaxSlashingsPerBlock;
    }

    // _______________ External Functions _______________

    /**
     * @notice Set or update BLS contract address
     * @param blsAddr Address of the BLS contract
     */
    function setBLSAddress(address blsAddr) external onlySystemCall {
        bls = IBLS(blsAddr);
    }

    /**
     * @notice Update the penalty percentage for double signing
     * @dev Only callable by system (governance decision)
     * @param newPercentage New penalty percentage in basis points (0-10000)
     */
    function setPenaltyPercentage(uint256 newPercentage) external onlySystemCall {
        if (newPercentage > MAX_PENALTY_PERCENTAGE) revert InvalidPenaltyPercentage();

        uint256 oldPercentage = doubleSignPenaltyPercentage;
        doubleSignPenaltyPercentage = newPercentage;

        emit PenaltyPercentageUpdated(oldPercentage, newPercentage);
    }

    /**
     * @notice Update the maximum slashings allowed per block
     * @dev Protection against mass slashing events due to bugs
     * @param newMax New maximum slashings per block
     */
    function setMaxSlashingsPerBlock(uint256 newMax) external onlySystemCall {
        uint256 oldMax = maxSlashingsPerBlock;
        maxSlashingsPerBlock = newMax;

        emit MaxSlashingsPerBlockUpdated(oldMax, newMax);
    }

    /**
     * @notice Validates double-signing evidence and triggers Inspector's ban mechanism
     * @dev This is the ONLY entry point for slashing. It:
     *      1. Validates cryptographic evidence
     *      2. Stores evidence for auditing
     *      3. Delegates to Inspector.slashValidator()
     *
     *      Inspector will then:
     *      - Call HydraStaking.penalizeStaker() with configured penalty
     *      - Execute ban logic
     *
     *      This reuses existing infrastructure per client requirements.
     *
     * @param validator Address of the validator to slash
     * @param msg1 First conflicting IBFT message
     * @param msg2 Second conflicting IBFT message
     * @param reason Reason for slashing
     */
    function slashValidator(
        address validator,
        IBFTMessage calldata msg1,
        IBFTMessage calldata msg2,
        string calldata reason
    ) external onlySystemCall {
        // Protection: Check if already slashed
        if (validator == address(0)) revert InvalidValidatorAddress();
        if (_hasBeenSlashed[validator]) revert ValidatorAlreadySlashed();
        if (address(bls) == address(0)) revert BLSNotSet();

        // Protection: Prevent mass slashing in single block
        if (slashingsInBlock[block.number] >= maxSlashingsPerBlock) {
            revert MaxSlashingsExceeded();
        }

        // Validate evidence structure
        _validateEvidence(validator, msg1, msg2);

        // Verify BLS signatures
        _verifyBLSSignatures(validator, msg1, msg2);

        // Store evidence for auditing
        bytes32 evidenceHash = keccak256(abi.encode(msg1, msg2));
        slashingEvidenceHash[validator] = evidenceHash;

        // Mark as slashed to prevent double slashing
        _hasBeenSlashed[validator] = true;

        // Increment slashing counter for this block
        slashingsInBlock[block.number]++;

        // Emit detailed evidence event
        emit DoubleSignEvidence(
            validator,
            evidenceHash,
            msg1.height,
            msg1.round,
            keccak256(msg1.data),
            keccak256(msg2.data)
        );

        // Delegate to Inspector's existing ban mechanism
        // Inspector will call penalizeStaker with the configured penalty
        // This reuses existing infrastructure and minimizes code changes
        IInspector(hydraChainContract).slashValidator(validator, reason);

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
     * @notice Get the evidence hash for a slashed validator
     * @param validator Address of the validator
     * @return The stored evidence hash
     */
    function getEvidenceHash(address validator) external view returns (bytes32) {
        return slashingEvidenceHash[validator];
    }

    /**
     * @notice Get current penalty percentage
     * @return Penalty percentage in basis points
     */
    function getPenaltyPercentage() external view returns (uint256) {
        return doubleSignPenaltyPercentage;
    }

    /**
     * @notice Get slashings count for current block
     * @return Number of slashings in current block
     */
    function getSlashingsInCurrentBlock() external view returns (uint256) {
        return slashingsInBlock[block.number];
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
            revert EvidenceMismatch("from != validator");
        }

        // Messages must be from the same height
        if (msg1.height != msg2.height) {
            revert EvidenceMismatch("height mismatch");
        }

        // Messages must be from the same round
        if (msg1.round != msg2.round) {
            revert EvidenceMismatch("round mismatch");
        }

        // Messages must be of the same type
        if (msg1.msgType != msg2.msgType) {
            revert EvidenceMismatch("type mismatch");
        }

        // Messages must have different data (this is the conflicting part)
        if (keccak256(msg1.data) == keccak256(msg2.data)) {
            revert EvidenceMismatch("identical data");
        }

        // Signatures must be different
        if (keccak256(msg1.signature) == keccak256(msg2.signature)) {
            revert EvidenceMismatch("identical signatures");
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
        require(ok1, "msg1 signature invalid");

        (bool ok2, ) = bls.verifySingle(sig2, pubkey, msg2ForBLS);
        require(ok2, "msg2 signature invalid");
    }

    // _______________ Gap for Upgradeability _______________

    // slither-disable-next-line unused-state,naming-convention
    uint256[50] private __gap;
}
