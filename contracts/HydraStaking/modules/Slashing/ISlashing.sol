// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface ISlashing {
    /// @notice Emitted when a validator is slashed
    event ValidatorSlashed(address indexed validator, string reason);

    /// @notice Slashes a validator's stake for misbehavior
    /// @param validator The address of the validator to slash
    /// @param reason The reason for slashing
    function slashValidator(address validator, string calldata reason) external;

    /// @notice Returns the slashed amount for a validator
    /// @param validator The address of the validator
    /// @return The total amount slashed
    function getSlashedAmount(address validator) external view returns (uint256);

    /// @notice Returns whether a validator is slashed
    /// @param validator The address of the validator
    /// @return True if the validator is slashed
    function isSlashed(address validator) external view returns (bool);
} 