// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ISlashing} from "./ISlashing.sol";
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

    /// @notice Whistleblower reward percentage (in basis points, e.g., 500 = 5%)
    uint256 public whistleblowerRewardPercentage;

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
        uint256 amount; // Amount of slashed stake locked
        uint256 lockTimestamp; // When the funds were locked
        bool withdrawn; // Whether funds have been withdrawn
    }

    /// @notice Mapping of validator address to their locked slashed funds
    mapping(address => LockedFunds) public lockedFunds;

    /// @notice Mapping to track reporter (whistleblower) for each slashed validator
    mapping(address => address) public slashingReporter;

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
        uint8 msgType,
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

    /// @notice Emitted when whistleblower receives reward
    event WhistleblowerRewarded(address indexed reporter, address indexed validator, uint256 reward);

    /// @notice Emitted when whistleblower reward percentage is updated
    event WhistleblowerRewardPercentageUpdated(uint256 oldPercentage, uint256 newPercentage);

    /// @notice Emitted when governance address is updated
    event GovernanceUpdated(address indexed oldGovernance, address indexed newGovernance);

    /// @notice Emitted when DAO treasury address is updated
    event DaoTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Emitted when contract is initialized
    event SlashingContractInitialized(address hydraChain, address governance);

    /// @notice Emitted when a reporter is stored for a slashed validator
    event ReporterStored(address indexed validator, address indexed reporter);

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
     * @param initialWhistleblowerRewardPercentage Initial whistleblower reward (basis points, e.g., 500 = 5%)
     */
    function initialize(
        address hydraChainAddr,
        address hydraStakingAddr,
        address governanceAddr,
        address daoTreasuryAddr,
        uint256 initialMaxSlashingsPerBlock,
        uint256 initialWhistleblowerRewardPercentage
    ) external onlySystemCall {
        require(!_initialized, "Already initialized");
        require(hydraChainAddr != address(0), "Invalid HydraChain address");
        require(hydraStakingAddr != address(0), "Invalid HydraStaking address");
        require(governanceAddr != address(0), "Invalid governance address");
        require(initialWhistleblowerRewardPercentage <= 1000, "Reward cannot exceed 10%"); // Max 10%

        // Validate that addresses point to actual contracts
        require(hydraChainAddr.code.length > 0, "HydraChain must be a contract");
        require(hydraStakingAddr.code.length > 0, "HydraStaking must be a contract");
        // Note: governanceAddr can be EOA (multisig or governance contract)
        // Note: daoTreasuryAddr can be zero or EOA initially

        hydraChainContract = hydraChainAddr;
        hydraStakingContract = hydraStakingAddr;
        governance = governanceAddr;
        daoTreasury = daoTreasuryAddr; // Can be zero address initially
        maxSlashingsPerBlock = initialMaxSlashingsPerBlock;
        whistleblowerRewardPercentage = initialWhistleblowerRewardPercentage;

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
     * @notice Update the whistleblower reward percentage
     * @dev Reward must not exceed 10% (1000 basis points)
     * @param newPercentage New reward percentage in basis points (e.g., 500 = 5%)
     */
    function setWhistleblowerRewardPercentage(uint256 newPercentage) external onlyGovernance {
        require(newPercentage <= 1000, "Reward cannot exceed 10%");

        uint256 oldPercentage = whistleblowerRewardPercentage;
        whistleblowerRewardPercentage = newPercentage;

        emit WhistleblowerRewardPercentageUpdated(oldPercentage, newPercentage);
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
     * @param reporter Address of the validator who reported/included this evidence (block proposer)
     */
    function slashValidator(
        address validator,
        bytes32 msg1Hash,
        bytes memory msg1Sig,
        bytes32 msg2Hash,
        bytes memory msg2Sig,
        uint64 height,
        uint64 round,
        uint8 msgType,
        string calldata reason,
        address reporter
    ) external onlySystemCall {
        // Protection checks
        if (validator == address(0)) revert InvalidValidatorAddress();
        if (_hasBeenSlashed[validator]) revert ValidatorAlreadySlashed();
        if (msg1Hash == msg2Hash) revert EvidenceMismatch("identical data hashes");
        if (slashingsInBlock[block.number] >= maxSlashingsPerBlock) revert MaxSlashingsExceeded();

        // Validate evidence height and round values
        require(height > 0, "Height must be greater than 0");
        require(height <= block.number + 100, "Height too far in future");
        // Prevent replay of old evidence (10000 blocks = ~8 hours on 3s block time)
        if (block.number > 10000 && height < block.number) {
            require(block.number - height <= 10000, "Evidence too old");
        }

        // Verify signatures and execute slashing
        _verifyAndSlash(validator, msg1Hash, msg1Sig, msg2Hash, msg2Sig, height, round, msgType, reason, reporter);
    }

    /**
     * @notice Internal function to verify signatures and execute slashing
     * @dev Split from slashValidator to avoid stack too deep errors
     */
    function _verifyAndSlash(
        address validator,
        bytes32 msg1Hash,
        bytes memory msg1Sig,
        bytes32 msg2Hash,
        bytes memory msg2Sig,
        uint64 height,
        uint64 round,
        uint8 msgType,
        string calldata reason,
        address reporter
    ) private {
        // Verify ECDSA signatures using pre-computed hashes
        if (_recoverSigner(msg1Hash, msg1Sig) != validator) {
            revert InvalidSignature("msg1 signature does not match validator");
        }

        if (_recoverSigner(msg2Hash, msg2Sig) != validator) {
            revert InvalidSignature("msg2 signature does not match validator");
        }

        // Store evidence and mark as slashed
        slashingEvidenceHash[validator] = keccak256(abi.encodePacked(msg1Hash, msg2Hash));
        _hasBeenSlashed[validator] = true;
        slashingsInBlock[block.number]++;

        // Store the reporter (whistleblower) for reward distribution
        if (reporter != address(0)) {
            require(reporter != validator, "Reporter cannot be slashed validator");
            slashingReporter[validator] = reporter;
            emit ReporterStored(validator, reporter);
        }

        // Emit events and execute slashing
        emit DoubleSignEvidence(validator, slashingEvidenceHash[validator], height, round, msgType, msg1Hash, msg2Hash);

        // Direct call without try-catch
        IInspector(hydraChainContract).slashValidator(validator, reason);

        emit ValidatorSlashed(validator, reason);
    }

    /**
     * @notice Lock slashed funds for a validator (funds stay in HydraStaking)
     * @dev Called by Inspector contract during slashing. Removes from active stake and locks for governance decision.
     *      Automatically distributes whistleblower reward to the reporter if configured.
     * @param validator Address of the slashed validator
     * @param amount Amount to lock
     */
    function lockSlashedFunds(address validator, uint256 amount) external {
        // Allow calls from HydraChain contract (Inspector) during slashing flow
        require(msg.sender == hydraChainContract || msg.sender == SYSTEM, "Only HydraChain or SYSTEM can lock funds");
        require(amount > 0, "No funds to lock");
        require(validator != address(0), "Invalid validator address");

        // Prevent double-locking funds for the same validator
        require(
            lockedFunds[validator].amount == 0 || lockedFunds[validator].withdrawn,
            "Funds already locked for this validator"
        );

        // Get the reporter from storage (set in slashValidator)
        address reporter = slashingReporter[validator];

        // Calculate whistleblower reward
        uint256 whistleblowerReward = 0;
        uint256 amountToLock = amount;

        if (reporter != address(0) && whistleblowerRewardPercentage > 0) {
            whistleblowerReward = (amount * whistleblowerRewardPercentage) / 10000;
            amountToLock = amount - whistleblowerReward;

            emit WhistleblowerRewarded(reporter, validator, whistleblowerReward);
        }

        // Call HydraStaking to remove stake from active balance and distribute whistleblower reward
        // HydraStaking will send the whistleblowerReward to the reporter directly
        IHydraStaking(hydraStakingContract).lockStakeForSlashing(validator, amount, whistleblowerReward, reporter);

        // Record the locked amount (funds stay in HydraStaking contract)
        // Only lock the remaining amount after whistleblower reward
        lockedFunds[validator] = LockedFunds({amount: amountToLock, lockTimestamp: block.timestamp, withdrawn: false});

        uint256 unlockTime = block.timestamp + LOCK_PERIOD;
        emit FundsLocked(validator, amountToLock, unlockTime);
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

        // Call HydraStaking to burn the funds from its balance
        IHydraStaking(hydraStakingContract).burnSlashedFunds(amount);

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

        // Call HydraStaking to send the funds to treasury from its balance
        IHydraStaking(hydraStakingContract).sendSlashedFundsToTreasury(amount, daoTreasury);

        emit FundsSentToTreasury(validator, amount, daoTreasury);
    }

    /**
     * @notice Burn locked funds for multiple validators
     * @param validators Array of validator addresses
     */
    function batchBurnLockedFunds(address[] calldata validators) external onlyGovernance {
        for (uint256 i = 0; i < validators.length; i++) {
            address validator = validators[i];

            if (
                lockedFunds[validator].withdrawn ||
                lockedFunds[validator].amount == 0 ||
                block.timestamp < lockedFunds[validator].lockTimestamp + LOCK_PERIOD
            ) {
                continue;
            }

            uint256 amount = lockedFunds[validator].amount;
            lockedFunds[validator].withdrawn = true;

            // Call HydraStaking to burn the funds
            try IHydraStaking(hydraStakingContract).burnSlashedFunds(amount) {
                emit FundsBurned(validator, amount, msg.sender);
            } catch {
                // Revert the withdrawn flag if burn failed
                lockedFunds[validator].withdrawn = false;
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

            if (
                lockedFunds[validator].withdrawn ||
                lockedFunds[validator].amount == 0 ||
                block.timestamp < lockedFunds[validator].lockTimestamp + LOCK_PERIOD
            ) {
                continue;
            }

            uint256 amount = lockedFunds[validator].amount;
            lockedFunds[validator].withdrawn = true;

            // Call HydraStaking to send funds to treasury
            try IHydraStaking(hydraStakingContract).sendSlashedFundsToTreasury(amount, daoTreasury) {
                emit FundsSentToTreasury(validator, amount, daoTreasury);
            } catch {
                // Revert the withdrawn flag if transfer failed
                lockedFunds[validator].withdrawn = false;
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

        // Prevent signature malleability (EIP-2)
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSignature("Invalid s value - signature malleability detected");
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
