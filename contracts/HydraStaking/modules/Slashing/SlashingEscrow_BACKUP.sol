// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {System} from "../../../common/System/System.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title SlashingEscrow
 * @notice Holds slashed funds in escrow for 30 days before governance can withdraw
 * @dev This contract implements the client's requirement:
 *      - 100% of slashed stake is locked here
 *      - Funds locked for 30 days
 *      - After 30 days, governance can decide per-validator: burn or send to DAO treasury
 */
contract SlashingEscrow is System, Initializable {
    // _______________ Constants _______________

    /// @notice Lock period before funds can be withdrawn (30 days in seconds)
    uint256 public constant LOCK_PERIOD = 30 days;

    // _______________ State Variables _______________

    /// @notice Address that can withdraw funds after lock period (governance)
    address public governance;

    /// @notice DAO treasury address (optional destination for slashed funds)
    address public daoTreasury;

    /// @notice Tracks locked funds per validator
    struct LockedFunds {
        uint256 amount;          // Amount of slashed stake locked
        uint256 lockTimestamp;   // When the funds were locked
        bool withdrawn;          // Whether funds have been withdrawn
    }

    /// @notice Mapping of validator address to their locked slashed funds
    mapping(address => LockedFunds) public lockedFunds;

    // _______________ Events _______________

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

    // _______________ Custom Errors _______________

    error OnlyGovernance();
    error FundsStillLocked(uint256 unlockTime);
    error NoLockedFunds();
    error AlreadyWithdrawn();
    error InvalidAddress();
    error TransferFailed();

    // _______________ Modifiers _______________

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    // _______________ Initializer _______________

    /**
     * @notice Initializer for upgradeable pattern
     * @param governanceAddr Address of governance (can withdraw after lock period)
     * @param daoTreasuryAddr Address of DAO treasury (optional destination)
     */
    function initialize(
        address governanceAddr,
        address daoTreasuryAddr
    ) external initializer onlySystemCall {
        require(governanceAddr != address(0), "Invalid governance address");

        governance = governanceAddr;
        daoTreasury = daoTreasuryAddr; // Can be zero address initially
    }

    // _______________ External Functions _______________

    /**
     * @notice Lock slashed funds for a validator
     * @dev Only callable by system (from Inspector contract during slashing)
     * @param validator Address of the slashed validator
     */
    function lockFunds(address validator) external payable onlySystemCall {
        require(msg.value > 0, "No funds to lock");
        require(validator != address(0), "Invalid validator address");

        // If validator already has locked funds, this is a re-slash (shouldn't happen due to hasBeenSlashed check)
        // But handle it by adding to existing amount and resetting the lock period
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
     * @notice Batch burn locked funds for multiple validators
     * @dev Gas-efficient way to burn multiple validators' funds
     * @param validators Array of validator addresses
     */
    function batchBurnLockedFunds(address[] calldata validators) external onlyGovernance {
        for (uint256 i = 0; i < validators.length; i++) {
            address validator = validators[i];

            // Skip if not withdrawable (already withdrawn or still locked)
            if (lockedFunds[validator].withdrawn ||
                lockedFunds[validator].amount == 0 ||
                block.timestamp < lockedFunds[validator].lockTimestamp + LOCK_PERIOD) {
                continue;
            }

            uint256 amount = lockedFunds[validator].amount;
            lockedFunds[validator].withdrawn = true;

            // Burn by sending to address(0)
            (bool success, ) = address(0).call{value: amount}("");
            if (success) {
                emit FundsBurned(validator, amount, msg.sender);
            }
        }
    }

    /**
     * @notice Batch send locked funds to treasury for multiple validators
     * @dev Gas-efficient way to send multiple validators' funds to treasury
     * @param validators Array of validator addresses
     */
    function batchSendToTreasury(address[] calldata validators) external onlyGovernance {
        if (daoTreasury == address(0)) revert InvalidAddress();

        for (uint256 i = 0; i < validators.length; i++) {
            address validator = validators[i];

            // Skip if not withdrawable
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

    // _______________ View Functions _______________

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
