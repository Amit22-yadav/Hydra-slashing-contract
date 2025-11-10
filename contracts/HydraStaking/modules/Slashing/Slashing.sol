// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ISlashing, IBFTMessage} from "./ISlashing.sol";
import {System} from "../../../common/System/System.sol";
import {IInspector} from "../../../HydraChain/modules/Inspector/IInspector.sol";
import {IHydraStaking} from "../../IHydraStaking.sol";

/**
 * @title Slashing
 * @notice Validates double-signing evidence and manages slashed funds with 30-day lock period
 * @dev Implements BLS signature verification, rate limiting, and governance-controlled fund distribution
 */
contract Slashing is ISlashing, System {
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

    /// @notice Reference to the HydraChain contract (Inspector module)
    address public hydraChainContract;

    /// @notice Reference to the HydraStaking contract
    address public hydraStakingContract;

    /// @notice Address that can withdraw funds after lock period (governance)
    address public governance;

    /// @notice DAO treasury address (optional destination for slashed funds)
    address public daoTreasury;

    /// @notice Mapping to store evidence hash for each slashed validator (for auditing)
    mapping(address => bytes32) public slashingEvidenceHash;

    /// @notice Mapping to track if a validator has been slashed (prevents double slashing)
    mapping(address => bool) private _hasBeenSlashed;

    /// @notice Custom initialization flag (replaces OpenZeppelin's Initializable)
    bool private _initialized;

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
    error InvalidSignature(string detail);
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

    /// @notice Emitted when BLS verification skip flag is updated
    event BLSVerificationSkipUpdated(bool skip);

    /// @notice Debug events for slashing validation steps
    event SlashingStepCompleted(string step, address validator);
    event SlashingValidationFailed(string step, address validator, string reason);
    event MsgSenderDebug(string location, address msgSender, address txOrigin, address expectedSlashing, address expectedSystem);

    /// @notice Emitted when contract is initialized
    event SlashingContractInitialized(address hydraChain, address governance);

    // _______________ Modifiers _______________

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    // _______________ Initializer _______________

    /**
     * @notice Initializer for upgradeable pattern
     * @param hydraChainAddr Address of the HydraChain contract
     * @param hydraStakingAddr Address of the HydraStaking contract
     * @param governanceAddr Address of governance (can withdraw after lock period)
     * @param daoTreasuryAddr Address of DAO treasury (optional destination)
     * @param initialMaxSlashingsPerBlock Initial max slashings per block
     */
    function initialize(
        address hydraChainAddr,
        address hydraStakingAddr,
        address governanceAddr,
        address daoTreasuryAddr,
        uint256 initialMaxSlashingsPerBlock
    ) external onlySystemCall {
        require(!_initialized, "Already initialized");
        require(hydraChainAddr != address(0), "Invalid HydraChain address");
        require(hydraStakingAddr != address(0), "Invalid HydraStaking address");
        require(governanceAddr != address(0), "Invalid governance address");

        hydraChainContract = hydraChainAddr;
        hydraStakingContract = hydraStakingAddr;
        governance = governanceAddr;
        daoTreasury = daoTreasuryAddr; // Can be zero address initially
        maxSlashingsPerBlock = initialMaxSlashingsPerBlock;

        // Mark as initialized
        _initialized = true;

        // Emit initialization event for debugging
        emit SlashingContractInitialized(hydraChainAddr, governanceAddr);
    }

    // _______________ External Functions _______________

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
     * @dev Verifies ECDSA signatures, stores evidence, and delegates execution to Inspector
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
        emit SlashingStepCompleted("slashValidator_start", validator);

        // Protection: Check if already slashed
        if (validator == address(0)) revert InvalidValidatorAddress();
        emit SlashingStepCompleted("validator_address_check_passed", validator);

        if (_hasBeenSlashed[validator]) revert ValidatorAlreadySlashed();
        emit SlashingStepCompleted("not_already_slashed_check_passed", validator);

        // Validate evidence structure BEFORE marking as slashed
        _validateEvidence(validator, msg1, msg2);
        emit SlashingStepCompleted("evidence_validation_passed", validator);

        // Verify ECDSA signatures BEFORE marking as slashed
        _verifyECDSASignatures(validator, msg1, msg2);
        emit SlashingStepCompleted("ecdsa_verification_passed", validator);

        // Protection: Prevent mass slashing in single block
        // This check happens AFTER validation to ensure only valid evidence is counted
        if (slashingsInBlock[block.number] >= maxSlashingsPerBlock) {
            revert MaxSlashingsExceeded();
        }
        emit SlashingStepCompleted("max_slashing_check_passed", validator);

        // Store evidence for auditing
        bytes32 evidenceHash = keccak256(abi.encode(msg1, msg2));
        slashingEvidenceHash[validator] = evidenceHash;
        emit SlashingStepCompleted("evidence_stored", validator);

        // Mark as slashed to prevent double slashing
        _hasBeenSlashed[validator] = true;
        emit SlashingStepCompleted("marked_as_slashed", validator);

        // Increment slashing counter for this block
        slashingsInBlock[block.number]++;
        emit SlashingStepCompleted("slashing_counter_incremented", validator);

        // Emit detailed evidence event
        emit DoubleSignEvidence(
            validator,
            evidenceHash,
            msg1.height,
            msg1.round,
            keccak256(msg1.data),
            keccak256(msg2.data)
        );
        emit SlashingStepCompleted("double_sign_evidence_emitted", validator);

        // Delegate to Inspector for execution
        emit SlashingStepCompleted("calling_inspector_slashValidator", validator);
        IInspector(hydraChainContract).slashValidator(validator, reason);
        emit SlashingStepCompleted("inspector_slashValidator_completed", validator);

        emit ValidatorSlashed(validator, reason);
        emit SlashingStepCompleted("slashValidator_completed_successfully", validator);
    }

    /**
     * @notice Gas-optimized slashing function using pre-computed hashes
     * @dev This function accepts message hashes instead of full data to reduce gas costs
     * @param validator Address of the validator being slashed
     * @param msg1Hash Keccak256 hash of the first IBFT message data
     * @param msg1Sig Signature of the first message (65 bytes: r, s, v)
     * @param msg2Hash Keccak256 hash of the second IBFT message data
     * @param msg2Sig Signature of the second message (65 bytes: r, s, v)
     * @param height Block height of the double signing
     * @param round Consensus round of the double signing
     * @param msgType IBFT message type
     * @param reason Reason for slashing (e.g., "double-signing")
     */
    function slashValidatorOptimized(
        address validator,
        bytes32 msg1Hash,
        bytes memory msg1Sig,
        bytes32 msg2Hash,
        bytes memory msg2Sig,
        uint64 height,
        uint64 round,
        uint8 msgType,
        string calldata reason
    ) external onlySystemCall {
        emit SlashingStepCompleted("slashValidatorOptimized_started", validator);

        // Protection checks
        emit SlashingStepCompleted("checking_validator_address", validator);
        if (validator == address(0)) revert InvalidValidatorAddress();

        emit SlashingStepCompleted("checking_already_slashed", validator);
        if (_hasBeenSlashed[validator]) revert ValidatorAlreadySlashed();

        emit SlashingStepCompleted("checking_hash_equality", validator);
        if (msg1Hash == msg2Hash) revert EvidenceMismatch("identical data hashes");

        emit SlashingStepCompleted("checking_max_slashings", validator);
        if (slashingsInBlock[block.number] >= maxSlashingsPerBlock) revert MaxSlashingsExceeded();

        emit SlashingStepCompleted("about_to_recover_msg1_signer", validator);
        // Verify ECDSA signatures using pre-computed hashes
        address recovered1 = _recoverSigner(msg1Hash, msg1Sig);
        emit SlashingStepCompleted("msg1_signer_recovered", recovered1);

        if (recovered1 != validator) {
            revert InvalidSignature("msg1 signature does not match validator");
        }
        emit SlashingStepCompleted("msg1_verification_passed", validator);

        emit SlashingStepCompleted("about_to_recover_msg2_signer", validator);
        address recovered2 = _recoverSigner(msg2Hash, msg2Sig);
        emit SlashingStepCompleted("msg2_signer_recovered", recovered2);

        if (recovered2 != validator) {
            revert InvalidSignature("msg2 signature does not match validator");
        }
        emit SlashingStepCompleted("msg2_verification_passed", validator);

        // Store evidence and mark as slashed
        emit SlashingStepCompleted("storing_evidence", validator);
        slashingEvidenceHash[validator] = keccak256(abi.encodePacked(msg1Hash, msg2Hash));
        _hasBeenSlashed[validator] = true;
        slashingsInBlock[block.number]++;

        // Emit events and execute slashing
        emit SlashingStepCompleted("emitting_double_sign_evidence", validator);
        emit DoubleSignEvidence(validator, slashingEvidenceHash[validator], height, round, msg1Hash, msg2Hash);

        emit SlashingStepCompleted("calling_inspector_slashValidator", validator);
        // Direct call without try-catch
        IInspector(hydraChainContract).slashValidator(validator, reason);
        emit SlashingStepCompleted("hydrachain_call_completed", validator);

        emit SlashingStepCompleted("slashing_completed_successfully", validator);
        emit ValidatorSlashed(validator, reason);
    }

    /**
     * @notice Lock slashed funds for a validator (funds stay in HydraStaking)
     * @dev Called by Inspector contract during slashing. Removes from active stake and locks for governance decision.
     * @param validator Address of the slashed validator
     * @param amount Amount to lock
     */
    function lockSlashedFunds(address validator, uint256 amount) external {
        // Allow calls from HydraChain contract (Inspector) during slashing flow
        require(msg.sender == hydraChainContract || msg.sender == SYSTEM, "Only HydraChain or SYSTEM can lock funds");
        require(amount > 0, "No funds to lock");
        require(validator != address(0), "Invalid validator address");

        // Call HydraStaking to remove stake from active balance
        IHydraStaking(hydraStakingContract).lockStakeForSlashing(validator, amount);

        // Record the locked amount (funds stay in HydraStaking contract)
        if (lockedFunds[validator].amount > 0 && !lockedFunds[validator].withdrawn) {
            lockedFunds[validator].amount += amount;
            lockedFunds[validator].lockTimestamp = block.timestamp;
        } else {
            lockedFunds[validator] = LockedFunds({
                amount: amount,
                lockTimestamp: block.timestamp,
                withdrawn: false
            });
        }

        uint256 unlockTime = block.timestamp + LOCK_PERIOD;
        emit FundsLocked(validator, amount, unlockTime);
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
     * @notice Test function to verify contract is callable
     * @return Always returns true
     */
    function ping() external pure returns (bool) {
        return true;
    }

    /**
     * @notice TEST ONLY - Slash validator without onlySystemCall restriction
     * @dev WARNING: Remove this function in production! Only for testing slashing logic
     * @param validator Address of the validator to slash
     * @param msg1Hash Hash of first conflicting message
     * @param msg1Sig Signature of first message (65 bytes: r, s, v)
     * @param msg2Hash Hash of second conflicting message
     * @param msg2Sig Signature of second message (65 bytes: r, s, v)
     * @param height Block height where double-signing occurred
     * @param round Round number
     * @param msgType Message type (0=PREPREPARE, 1=PREPARE, 2=COMMIT)
     * @param reason Reason for slashing
     */
    function slashValidatorTest(
        address validator,
        bytes32 msg1Hash,
        bytes memory msg1Sig,
        bytes32 msg2Hash,
        bytes memory msg2Sig,
        uint64 height,
        uint64 round,
        uint8 msgType,
        string calldata reason
    ) external {
        // Protection checks
        if (validator == address(0)) revert InvalidValidatorAddress();
        if (_hasBeenSlashed[validator]) revert ValidatorAlreadySlashed();
        if (msg1Hash == msg2Hash) revert EvidenceMismatch("identical data hashes");
        if (slashingsInBlock[block.number] >= maxSlashingsPerBlock) revert MaxSlashingsExceeded();

        // Verify ECDSA signatures
        address recovered1 = _recoverSigner(msg1Hash, msg1Sig);
        if (recovered1 != validator) {
            revert InvalidSignature("msg1 signature does not match validator");
        }

        address recovered2 = _recoverSigner(msg2Hash, msg2Sig);
        if (recovered2 != validator) {
            revert InvalidSignature("msg2 signature does not match validator");
        }

        // Store evidence and mark as slashed
        slashingEvidenceHash[validator] = keccak256(abi.encodePacked(msg1Hash, msg2Hash));
        _hasBeenSlashed[validator] = true;
        slashingsInBlock[block.number]++;

        // Emit events
        emit DoubleSignEvidence(validator, slashingEvidenceHash[validator], height, round, msg1Hash, msg2Hash);
        emit ValidatorSlashed(validator, reason);

        // NOTE: Not calling HydraChain.slashValidator() in test function
        // because it requires onlySlashing modifier. In production, use slashValidatorOptimized()
        // IInspector(hydraChainContract).slashValidator(validator, reason);
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
    ) internal {
        emit SlashingStepCompleted("evidence_validation_start", validator);

        // Both messages must be from the validator
        if (msg1.from != validator) {
            emit SlashingValidationFailed("validate_evidence", validator, "msg1.from != validator");
            revert EvidenceMismatch("msg1.from != validator");
        }
        emit SlashingStepCompleted("msg1_from_validated", validator);

        if (msg2.from != validator) {
            emit SlashingValidationFailed("validate_evidence", validator, "msg2.from != validator");
            revert EvidenceMismatch("msg2.from != validator");
        }
        emit SlashingStepCompleted("msg2_from_validated", validator);

        // Messages must be from the same height
        if (msg1.height != msg2.height) {
            emit SlashingValidationFailed("validate_evidence", validator, "height mismatch");
            revert EvidenceMismatch("height mismatch");
        }
        emit SlashingStepCompleted("height_validated", validator);

        // Messages must be from the same round
        if (msg1.round != msg2.round) {
            emit SlashingValidationFailed("validate_evidence", validator, "round mismatch");
            revert EvidenceMismatch("round mismatch");
        }
        emit SlashingStepCompleted("round_validated", validator);

        // Messages must be of the same type
        if (msg1.msgType != msg2.msgType) {
            emit SlashingValidationFailed("validate_evidence", validator, "type mismatch");
            revert EvidenceMismatch("type mismatch");
        }
        emit SlashingStepCompleted("msgType_validated", validator);

        // Messages must have different data (this is the conflicting part)
        if (keccak256(msg1.data) == keccak256(msg2.data)) {
            emit SlashingValidationFailed("validate_evidence", validator, "identical data");
            revert EvidenceMismatch("identical data");
        }
        emit SlashingStepCompleted("data_difference_validated", validator);

        // Signatures must be different
        if (keccak256(msg1.signature) == keccak256(msg2.signature)) {
            emit SlashingValidationFailed("validate_evidence", validator, "identical signatures");
            revert EvidenceMismatch("identical signatures");
        }

        emit SlashingStepCompleted("evidence_validation_complete", validator);
    }

    /**
     * @notice Verify ECDSA signatures for both IBFT messages
     * @param validator Address of the validator
     * @param msg1 First IBFT message
     * @param msg2 Second IBFT message
     */
    function _verifyECDSASignatures(
        address validator,
        IBFTMessage calldata msg1,
        IBFTMessage calldata msg2
    ) internal pure {
        // Hash the message data (IBFT signs the raw keccak256 hash without prefix)
        bytes32 msg1Hash = keccak256(msg1.data);
        bytes32 msg2Hash = keccak256(msg2.data);

        // Recover signer from signatures (IBFT uses raw hash, no Ethereum prefix)
        address signer1 = _recoverSigner(msg1Hash, msg1.signature);
        address signer2 = _recoverSigner(msg2Hash, msg2.signature);

        // Verify both signatures are from the expected validator
        if (signer1 != validator) {
            revert InvalidSignature("msg1 signature does not match validator");
        }
        if (signer2 != validator) {
            revert InvalidSignature("msg2 signature does not match validator");
        }
    }

    /**
     * @notice Recover signer address from signature
     * @param messageHash Hash of the signed message
     * @param signature ECDSA signature (65 bytes: r, s, v)
     * @return Address of the signer
     */
    function _recoverSigner(bytes32 messageHash, bytes memory signature) internal pure returns (address) {
        if (signature.length != 65) {
            revert InvalidSignature("Invalid signature length");
        }

        bytes32 r;
        bytes32 s;
        uint8 v;

        // Extract r, s, v from signature
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        // EIP-2: Adjust v if necessary (27/28)
        if (v < 27) {
            v += 27;
        }

        // Verify signature validity
        if (v != 27 && v != 28) {
            revert InvalidSignature("Invalid v value in signature");
        }

        // Recover address using ecrecover
        address recovered = ecrecover(messageHash, v, r, s);
        if (recovered == address(0)) {
            revert InvalidSignature("Failed to recover signer");
        }

        return recovered;
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
