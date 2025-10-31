// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

error OnlySlashing();
error InvalidValidatorAddress();
error ValidatorNotActive();
error ValidatorAlreadySlashed();
error ReasonStringTooLong();
error EscrowNotSet();

import {IBLS} from "../../../BLS/IBLS.sol";
import {Unauthorized} from "../../../common/Errors.sol";
import {PenalizedStakeDistribution} from "../../../HydraStaking/modules/PenalizeableStaking/IPenalizeableStaking.sol";
import {ValidatorManager, ValidatorStatus, ValidatorInit} from "../ValidatorManager/ValidatorManager.sol";
import {IInspector} from "./IInspector.sol";
import {IHydraStaking} from "../../../HydraStaking/IHydraStaking.sol";

// Interface for SlashingEscrow
interface ISlashingEscrow {
    function lockFunds(address validator) external payable;
}

/**
 * @title Inspector V3
 * @notice Manages validator lifecycle, banning, and slashing with 30-day escrow
 * @dev Updated to work with SlashingEscrow contract for 30-day locked funds
 *      Client requirements:
 *      - 100% slash for double signing
 *      - Funds locked in escrow for 30 days
 *      - Governance decides after 30 days: burn or send to DAO treasury
 */
abstract contract Inspector is IInspector, ValidatorManager {
    /// @notice The penalty that will be taken and burned from the bad validator's staked amount
    uint256 public validatorPenalty;
    /// @notice The reward for the person who reports a validator that have to be banned
    uint256 public reporterReward;
    /// @notice Threshold for validator inactiveness (in blocks).
    /// A ban can be initiated for a validator if this threshold is reached or exceeded.
    /// @dev must be always bigger than the epoch length (better bigger than at least 4 epochs),
    /// otherwise all validators can be banned
    uint256 public initiateBanThreshold;
    /// @notice Threshold for validator inactiveness (in seconds). A validator can be banned
    /// if it remains in the ban-initiated state for a duration equal to or exceeding this threshold.
    uint256 public banThreshold;
    /// @notice Mapping of the validators that bans has been initiated for (validator => timestamp)
    mapping(address => uint256) public bansInitiated;
    /// @notice Mapping to track if a validator has been slashed (prevents double slashing)
    mapping(address => bool) private _hasBeenSlashed;
    /// @notice Reference to the Slashing contract
    address public slashingContract;
    /// @notice Reference to the SlashingEscrow contract (holds locked funds)
    address public slashingEscrow;

    modifier onlySlashing() {
        if (msg.sender != slashingContract) revert OnlySlashing();
        _;
    }

    function setSlashingContract(address _slashing) external onlySystemCall {
        slashingContract = _slashing;
    }

    function setSlashingEscrow(address _escrow) external onlySystemCall {
        slashingEscrow = _escrow;
    }

    // _______________ Initializer _______________

    // solhint-disable-next-line func-name-mixedcase
    function __Inspector_init(
        ValidatorInit[] calldata newValidators,
        IBLS newBls,
        address hydraStakingAddr,
        address hydraDelegationAddr,
        address governance
    ) internal onlyInitializing {
        __ValidatorManager_init(newValidators, newBls, hydraStakingAddr, hydraDelegationAddr, governance);
        __Inspector_init_unchained();
    }

    // solhint-disable-next-line func-name-mixedcase
    function __Inspector_init_unchained() internal onlyInitializing {
        initiateBanThreshold = 18000; // in blocks => 1 hour minimum
        validatorPenalty = 700 ether;
        reporterReward = 300 ether;
        banThreshold = 24 hours;
    }

    // _______________ Modifiers _______________

    // Only address that is banned
    modifier onlyBanned(address account) {
        if (validators[account].status == ValidatorStatus.Banned) revert Unauthorized("UNBANNED_VALIDATOR");
        _;
    }

    // _______________ External functions _______________

    /**
     * @inheritdoc IInspector
     */
    function initiateBan(address validator) external {
        if (bansInitiated[validator] != 0) revert BanAlreadyInitiated();
        if (!isSubjectToInitiateBan(validator)) revert NoInitiateBanSubject();

        bansInitiated[validator] = block.timestamp;
        hydraStakingContract.temporaryEjectValidator(validator);
        hydraDelegationContract.lockCommissionReward(validator);
    }

    /**
     * @inheritdoc IInspector
     */
    function terminateBanProcedure() external {
        if (bansInitiated[msg.sender] == 0) revert NoBanInitiated();

        bansInitiated[msg.sender] = 0;
        _updateParticipation(msg.sender);
        hydraStakingContract.recoverEjectedValidator(msg.sender);
        hydraDelegationContract.unlockCommissionReward(msg.sender);
    }

    /**
     * @inheritdoc IInspector
     */
    function banValidator(address validator) external {
        if (!isSubjectToFinishBan(validator)) revert NoBanSubject();

        if (bansInitiated[validator] != 0) {
            bansInitiated[validator] = 0;
        }

        if (_isGovernance(msg.sender)) {
            hydraDelegationContract.lockCommissionReward(validator);
        }

        _ban(validator);
    }

    /**
     * @notice Slashes a validator's stake and locks it in escrow for 30 days
     * @dev Called by Slashing contract after evidence validation.
     *
     *      Flow:
     *      1. Validate validator is active and not already slashed
     *      2. Mark validator as slashed
     *      3. Get validator's current stake (100% will be slashed)
     *      4. Use penalizeStaker to transfer funds to THIS contract
     *      5. Forward funds to SlashingEscrow with lockFunds()
     *      6. Ban the validator
     *
     *      After 30 days, governance can call SlashingEscrow to:
     *      - burnLockedFunds(validator) - send to address(0)
     *      - sendToTreasury(validator) - send to DAO treasury
     *
     * @param validator Address of the validator to slash
     * @param reason Reason for slashing
     */
    function slashValidator(address validator, string calldata reason) external onlySlashing {
        if (validator == address(0)) revert InvalidValidatorAddress();
        if (validators[validator].status != ValidatorStatus.Active) revert ValidatorNotActive();
        if (_hasBeenSlashed[validator]) revert ValidatorAlreadySlashed();
        if (bytes(reason).length > 100) revert ReasonStringTooLong();
        if (slashingEscrow == address(0)) revert EscrowNotSet();

        // Mark validator as slashed to prevent double slashing
        _hasBeenSlashed[validator] = true;

        // Get the validator's current stake
        uint256 currentStake = hydraStakingContract.stakeOf(validator);
        require(currentStake > 0, "No stake to slash");

        // 100% penalty for double signing
        uint256 penaltyAmount = currentStake;

        // Use existing penalizeStaker pattern to transfer funds to THIS contract
        // This contract will then forward funds to SlashingEscrow
        PenalizedStakeDistribution[] memory distributions = new PenalizedStakeDistribution[](1);
        distributions[0] = PenalizedStakeDistribution({
            account: address(this), // Send to THIS contract first
            amount: penaltyAmount
        });

        // Reuse existing penalizeStaker infrastructure
        // This will transfer the slashed funds to THIS contract
        hydraStakingContract.penalizeStaker(validator, distributions);

        // Forward the slashed funds to SlashingEscrow with 30-day lock
        // SlashingEscrow will lock the funds and emit events
        ISlashingEscrow(slashingEscrow).lockFunds{value: penaltyAmount}(validator);

        // Ban the validator after slashing
        _ban(validator);

        emit ValidatorSlashed(validator, reason);
    }

    /**
     * @inheritdoc IInspector
     */
    function setValidatorPenalty(uint256 newPenalty) external onlyGovernance {
        validatorPenalty = newPenalty;
    }

    /**
     * @inheritdoc IInspector
     */
    function setReporterReward(uint256 newReward) external onlyGovernance {
        reporterReward = newReward;
    }

    /**
     * @inheritdoc IInspector
     */
    function setInitiateBanThreshold(uint256 newThreshold) external onlyGovernance {
        initiateBanThreshold = newThreshold;
    }

    /**
     * @inheritdoc IInspector
     */
    function setBanThreshold(uint256 newThreshold) external onlyGovernance {
        banThreshold = newThreshold;
    }

    /**
     * @inheritdoc IInspector
     */
    function banIsInitiated(address validator) external view returns (bool) {
        return bansInitiated[validator] != 0;
    }

    /**
     * @inheritdoc IInspector
     */
    function hasBeenSlashed(address validator) external view returns (bool) {
        return _hasBeenSlashed[validator];
    }

    // _______________ Public functions _______________

    /**
     * @inheritdoc IInspector
     */
    function isSubjectToFinishBan(address account) public view returns (bool) {
        if (validators[account].status == ValidatorStatus.Banned) {
            return false;
        }

        // check if the owner (governance) is calling
        if (_isGovernance(msg.sender)) {
            return true;
        }

        uint256 banInitiatedTimestamp = bansInitiated[account];
        if (banInitiatedTimestamp == 0 || block.timestamp - banInitiatedTimestamp < banThreshold) {
            return false;
        }

        return true;
    }

    /**
     * @notice Returns if a ban process can be initiated for a given validator
     * @dev This function is overridden in the hydra chain contract
     * @param account The address of the validator
     * @return Returns true if the validator is subject to initiate ban
     */
    function isSubjectToInitiateBan(address account) public virtual returns (bool);

    // _______________ Private functions _______________

    /**
     * @dev A method that executes the actions for the actual ban
     * @param account The account to ban
     */
    function _ban(address account) internal virtual;

    /**
     * @dev A method that updates the participation of a validator
     * @param validator The validator to update participation for
     */
    function _updateParticipation(address validator) internal virtual;

    /**
     * @notice Receive function to accept slashed funds from HydraStaking
     * @dev This contract receives funds from penalizeStaker before forwarding to escrow
     */
    receive() external payable {
        // Accept funds from HydraStaking.penalizeStaker
        // Funds will be forwarded to escrow in slashValidator function
    }

    // _______________ Gap for Upgradeability _______________

    // slither-disable-next-line unused-state,naming-convention
    uint256[50] private __gap;
}
