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
 * @notice Validates double-signing evidence and manages slashed funds with 30-day lock period
 * @dev Implements BLS signature verification, rate limiting, and governance-controlled fund distribution
 */
contract Slashing is ISlashing, System, Initializable {
    // _______________ Constants _______________

    /// @notice Penalty is always 100% for double signing
    uint256 public constant PENALTY_PERCENTAGE = 10000; // 100% in basis points

    /// @notice Lock period before funds can be withdrawn (30 days in seconds)
    uint256 public constant LOCK_PERIOD = 30 days;

    /// @notice Maximum validators that can be slashed in a single block
    uint256 public maxSlashingsPerBlock;

    /// @notice Tracks slashings per block for protection
    mapping(uint256 => uint256) public slashingsInBlock;

    // _______________ State Variables _______________

    /// @notice BLS contract for signature verification
    IBLS public bls;

    /// @notice Reference to the HydraChain contract (Inspector module)
    address public hydraChainContract;

    /// @notice Address that can withdraw funds after lock period (governance)
    address public governance;

    /// @notice DAO treasury address (optional destination for slashed funds)
    address public daoTreasury;

    /// @notice Mapping to store evidence hash for each slashed validator (for auditing)
    mapping(address => bytes32) public slashingEvidenceHash;

    /// @notice Mapping to track if a validator has been slashed (prevents double slashing)
    mapping(address => bool) private _hasBeenSlashed;

    /// @notice Tracks locked funds per validator
    struct LockedFunds {
        uint256 amount;          // Amount of slashed stake locked
        uint256 lockTimestamp;   // When the funds were locked
        bool withdrawn;          // Whether funds have been withdrawn
    }

    /// @notice Mapping of validator address to their locked slashed funds
    mapping(address => LockedFunds) public lockedFunds;

    // _______________ Custom Errors _______________

    error InvalidValidatorAddress();
    error ValidatorAlreadySlashed();
    error EvidenceMismatch(string detail);
    error BLSNotSet();
    error MaxSlashingsExceeded();
    error OnlyGovernance();
    error FundsStillLocked(uint256 unlockTime);
    error NoLockedFunds();
    error AlreadyWithdrawn();
    error InvalidAddress();
    error TransferFailed();

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

    /// @notice Emitted when max slashings per block is updated
    event MaxSlashingsPerBlockUpdated(uint256 oldMax, uint256 newMax);

    /// @notice Emitted when funds are locked in escrow
    event FundsLocked(address indexed validator, uint256 amount, uint256 unlockTime);

    /// @notice Emitted when governance burns locked funds
    event FundsBurned(address indexed validator, uint256 amount, address indexed burnedBy);

    /// @notice Emitted when governance sends funds to DAO treasury
    event FundsSentToTreasury(address indexed validator, uint256 amount, address indexed treasury);

    /// @notice Emitted when governance address is updated
    event GovernanceUpdated(address indexed oldGovernance, address indexed newGovernance);

    /// @notice Emitted when DAO treasury address is updated
    event DaoTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // _______________ Modifiers _______________

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    // _______________ Initializer _______________

    /**
     * @notice Initializer for upgradeable pattern
     * @param hydraChainAddr Address of the HydraChain contract
     * @param governanceAddr Address of governance (can withdraw after lock period)
     * @param daoTreasuryAddr Address of DAO treasury (optional destination)
     * @param initialMaxSlashingsPerBlock Initial max slashings per block
     */
    function initialize(
        address hydraChainAddr,
        address governanceAddr,
        address daoTreasuryAddr,
        uint256 initialMaxSlashingsPerBlock
    ) external initializer onlySystemCall {
        require(hydraChainAddr != address(0), "Invalid HydraChain address");
        require(governanceAddr != address(0), "Invalid governance address");

        hydraChainContract = hydraChainAddr;
        governance = governanceAddr;
        daoTreasury = daoTreasuryAddr; // Can be zero address initially
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
     * @notice Update the maximum slashings allowed per block
     * @dev Protection against mass slashing events due to bugs
     * @param newMax New maximum slashings per block
     */
    function setMaxSlashingsPerBlock(uint256 newMax) external onlyGovernance {
        uint256 oldMax = maxSlashingsPerBlock;
        maxSlashingsPerBlock = newMax;

        emit MaxSlashingsPerBlockUpdated(oldMax, newMax);
    }

    /**
     * @notice Validates double-signing evidence and initiates slashing process
     * @dev Verifies BLS signatures, stores evidence, and delegates execution to Inspector
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

        // Delegate to Inspector for execution
        IInspector(hydraChainContract).slashValidator(validator, reason);

        emit ValidatorSlashed(validator, reason);
    }

    /**
     * @notice Lock slashed funds for a validator with 30-day lock period
     * @dev Called by Inspector contract during slashing
     * @param validator Address of the slashed validator
     */
    function lockFunds(address validator) external payable onlySystemCall {
        require(msg.value > 0, "No funds to lock");
        require(validator != address(0), "Invalid validator address");

        if (lockedFunds[validator].amount > 0 && !lockedFunds[validator].withdrawn) {
            lockedFunds[validator].amount += msg.value;
            lockedFunds[validator].lockTimestamp = block.timestamp;
        } else {
            lockedFunds[validator] = LockedFunds({
                amount: msg.value,
                lockTimestamp: block.timestamp,
                withdrawn: false
            });
        }

        uint256 unlockTime = block.timestamp + LOCK_PERIOD;
        emit FundsLocked(validator, msg.value, unlockTime);
    }

    /**
     * @notice Burn locked funds for a specific validator (send to address(0))
     * @dev Only callable by governance after lock period
     * @param validator Address of the slashed validator
     */
    function burnLockedFunds(address validator) external onlyGovernance {
        _checkWithdrawable(validator);

        uint256 amount = lockedFunds[validator].amount;
        lockedFunds[validator].withdrawn = true;

        // Burn by sending to address(0)
        (bool success, ) = address(0).call{value: amount}("");
        if (!success) revert TransferFailed();

        emit FundsBurned(validator, amount, msg.sender);
    }

    /**
     * @notice Send locked funds to DAO treasury for a specific validator
     * @dev Only callable by governance after lock period
     * @param validator Address of the slashed validator
     */
    function sendToTreasury(address validator) external onlyGovernance {
        if (daoTreasury == address(0)) revert InvalidAddress();
        _checkWithdrawable(validator);

        uint256 amount = lockedFunds[validator].amount;
        lockedFunds[validator].withdrawn = true;

        // Send to DAO treasury
        (bool success, ) = daoTreasury.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit FundsSentToTreasury(validator, amount, daoTreasury);
    }

    /**
     * @notice Burn locked funds for multiple validators
     * @param validators Array of validator addresses
     */
    function batchBurnLockedFunds(address[] calldata validators) external onlyGovernance {
        for (uint256 i = 0; i < validators.length; i++) {
            address validator = validators[i];

            if (lockedFunds[validator].withdrawn ||
                lockedFunds[validator].amount == 0 ||
                block.timestamp < lockedFunds[validator].lockTimestamp + LOCK_PERIOD) {
                continue;
            }

            uint256 amount = lockedFunds[validator].amount;
            lockedFunds[validator].withdrawn = true;

            (bool success, ) = address(0).call{value: amount}("");
            if (success) {
                emit FundsBurned(validator, amount, msg.sender);
            }
        }
    }

    /**
     * @notice Send locked funds to treasury for multiple validators
     * @param validators Array of validator addresses
     */
    function batchSendToTreasury(address[] calldata validators) external onlyGovernance {
        if (daoTreasury == address(0)) revert InvalidAddress();

        for (uint256 i = 0; i < validators.length; i++) {
            address validator = validators[i];

            if (lockedFunds[validator].withdrawn ||
                lockedFunds[validator].amount == 0 ||
                block.timestamp < lockedFunds[validator].lockTimestamp + LOCK_PERIOD) {
                continue;
            }

            uint256 amount = lockedFunds[validator].amount;
            lockedFunds[validator].withdrawn = true;

            (bool success, ) = daoTreasury.call{value: amount}("");
            if (success) {
                emit FundsSentToTreasury(validator, amount, daoTreasury);
            }
        }
    }

    /**
     * @notice Update governance address
     * @param newGovernance New governance address
     */
    function setGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidAddress();

        address oldGovernance = governance;
        governance = newGovernance;

        emit GovernanceUpdated(oldGovernance, newGovernance);
    }

    /**
     * @notice Update DAO treasury address
     * @param newTreasury New DAO treasury address
     */
    function setDaoTreasury(address newTreasury) external onlyGovernance {
        if (newTreasury == address(0)) revert InvalidAddress();

        address oldTreasury = daoTreasury;
        daoTreasury = newTreasury;

        emit DaoTreasuryUpdated(oldTreasury, newTreasury);
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
     * @notice Get current penalty percentage (always 100%)
     * @return Penalty percentage in basis points (10000 = 100%)
     */
    function getPenaltyPercentage() external pure returns (uint256) {
        return PENALTY_PERCENTAGE;
    }

    /**
     * @notice Get slashings count for current block
     * @return Number of slashings in current block
     */
    function getSlashingsInCurrentBlock() external view returns (uint256) {
        return slashingsInBlock[block.number];
    }

    /**
     * @notice Check if funds are unlocked and ready for withdrawal
     * @param validator Address of the validator
     * @return True if funds can be withdrawn
     */
    function isUnlocked(address validator) external view returns (bool) {
        if (lockedFunds[validator].amount == 0) return false;
        if (lockedFunds[validator].withdrawn) return false;
        return block.timestamp >= lockedFunds[validator].lockTimestamp + LOCK_PERIOD;
    }

    /**
     * @notice Get unlock timestamp for a validator's locked funds
     * @param validator Address of the validator
     * @return Timestamp when funds can be withdrawn
     */
    function getUnlockTime(address validator) external view returns (uint256) {
        if (lockedFunds[validator].amount == 0) return 0;
        return lockedFunds[validator].lockTimestamp + LOCK_PERIOD;
    }

    /**
     * @notice Get remaining lock time for a validator's funds
     * @param validator Address of the validator
     * @return Seconds remaining until unlock (0 if already unlocked)
     */
    function getRemainingLockTime(address validator) external view returns (uint256) {
        if (lockedFunds[validator].amount == 0) return 0;
        if (lockedFunds[validator].withdrawn) return 0;

        uint256 unlockTime = lockedFunds[validator].lockTimestamp + LOCK_PERIOD;
        if (block.timestamp >= unlockTime) return 0;

        return unlockTime - block.timestamp;
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

    /**
     * @notice Internal check if funds are withdrawable
     * @param validator Address of the validator
     */
    function _checkWithdrawable(address validator) internal view {
        if (lockedFunds[validator].amount == 0) revert NoLockedFunds();
        if (lockedFunds[validator].withdrawn) revert AlreadyWithdrawn();

        uint256 unlockTime = lockedFunds[validator].lockTimestamp + LOCK_PERIOD;
        if (block.timestamp < unlockTime) {
            revert FundsStillLocked(unlockTime);
        }
    }

    // _______________ Gap for Upgradeability _______________

    // slither-disable-next-line unused-state,naming-convention
    uint256[50] private __gap;
}
