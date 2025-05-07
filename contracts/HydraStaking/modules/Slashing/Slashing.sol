// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ISlashing} from "./ISlashing.sol";
import {System} from "../../../common/System/System.sol";
import {Unauthorized} from "../../../common/Errors.sol";
import {Staking} from "../../Staking.sol";

contract Slashing is ISlashing, System {
    // Mapping to track slashed amounts per validator
    mapping(address => uint256) private _slashedAmounts;
    // Mapping to track if a validator is slashed
    mapping(address => bool) private _isSlashed;

    // Reference to the staking contract
    Staking public immutable STAKING_CONTRACT;

    constructor(address _stakingContract) {
        STAKING_CONTRACT = Staking(_stakingContract);
    }

    /// @inheritdoc ISlashing
    function slashValidator(address validator, uint256 amount, string calldata reason) external onlySystemCall {
        // Can only slash active validators
        if (STAKING_CONTRACT.stakeOf(validator) == 0) {
            revert Unauthorized("NOT_ACTIVE_VALIDATOR");
        }

        // Can't slash more than the validator's stake
        uint256 currentStake = STAKING_CONTRACT.stakeOf(validator);
        if (amount > currentStake) {
            amount = currentStake;
        }

        // Update slashed amount and status
        _slashedAmounts[validator] += amount;
        _isSlashed[validator] = true;

        // Call the staking contract's internal unstake function
        // This requires the staking contract to expose an internal unstake function
        STAKING_CONTRACT.unstakeFor(validator, amount);
        
        emit ValidatorSlashed(validator, amount, reason);
    }

    /// @inheritdoc ISlashing
    function getSlashedAmount(address validator) external view returns (uint256) {
        return _slashedAmounts[validator];
    }

    /// @inheritdoc ISlashing
    function isSlashed(address validator) external view returns (bool) {
        return _isSlashed[validator];
    }
} 