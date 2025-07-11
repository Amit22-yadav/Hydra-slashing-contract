// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Uptime} from "../HydraChain/modules/ValidatorManager/IValidatorManager.sol";
import {ILiquidStaking} from "./modules/LiquidStaking/ILiquidStaking.sol";
import {IDelegatedStaking} from "./modules/DelegatedStaking/IDelegatedStaking.sol";
import {IPenalizeableStaking} from "./modules/PenalizeableStaking/IPenalizeableStaking.sol";
import {IVestedStaking} from "./modules/VestedStaking/IVestedStaking.sol";

struct StakerInit {
    address addr;
    uint256 stake;
}

interface IHydraStaking is IDelegatedStaking, ILiquidStaking, IPenalizeableStaking, IVestedStaking {
    error DistributeRewardFailed(string message);

    /**
     * @notice Distributes rewards for the given epoch
     * @dev The function updates the rewards in the Staking and Delegation contracts' state
     * @param epochId The epoch number
     * @param uptime uptime data for every validator (staker)
     */
    function distributeRewardsFor(uint256 epochId, Uptime[] calldata uptime) external;

    /**
     * Allows temporary removal of a validator from the validator set by emitting a balance changed event
     * @dev It breaks the normal flow of the system contracts
     * but is the fastest way to achieve two-step ban functionality
     * @param account address of the validator to be removed
     */
    function temporaryEjectValidator(address account) external;

    /**
     * Return back a validator after temporary removal from the validator set by emitting a balance changed event
     * @dev related to the temporaryEjectValidator function
     * @param account address of the validator to be returned
     */
    function recoverEjectedValidator(address account) external;

    /**
     * @notice Slashes a validator's stake for misbehavior
     * @param validator The address of the validator to slash
     * @param reason The reason for slashing
     */
    function slashValidator(address validator, string calldata reason) external;

    /**
     * @notice Returns the slashed amount for a validator
     * @param validator The address of the validator
     * @return The total amount slashed
     */
    function getSlashedAmount(address validator) external view returns (uint256);

    /**
     * @notice Returns whether a validator has been slashed
     * @param validator The address of the validator
     * @return True if the validator has been slashed
     */
    function hasBeenSlashed(address validator) external view returns (bool);

    // _______________ Public functions _______________

    /**
     * @notice Returns total balance staked + delegated
     * @param staker The address of the staker
     */
    function totalBalanceOf(address staker) external view returns (uint256);

    /**
     * @notice Returns total staked balance for all stakers and delegators
     */
    function totalBalance() external view returns (uint256);
}
