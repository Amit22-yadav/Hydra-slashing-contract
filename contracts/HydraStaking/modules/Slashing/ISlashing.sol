// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface ISlashing {
    /// @notice Emitted when a validator is slashed
    event ValidatorSlashed(address indexed validator, string reason);

    /// @notice Slashes a validator's stake for misbehavior
    /// @param validator The address of the validator to slash
    /// @param reason The reason for slashing
    function slashValidator(address validator, string calldata reason) external;
} 