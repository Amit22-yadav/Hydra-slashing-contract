// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// IBFT consensus message structure for double-signing evidence
struct IBFTMessage {
    uint8 msgType;      // Type of IBFT message (PREPREPARE, PREPARE, COMMIT, ROUND_CHANGE)
    uint64 height;      // Block height
    uint64 round;       // Consensus round
    address from;       // Sender address
    bytes signature;    // BLS signature
    bytes data;         // Message payload
}

interface ISlashing {
    // _______________ Events _______________

    /// @notice Emitted when a validator is slashed
    event ValidatorSlashed(address indexed validator, string reason);

    // _______________ External Functions _______________

    /**
     * @notice Slashes a validator's stake for double-signing with cryptographic evidence
     * @param validator The address of the validator to slash
     * @param msg1 First conflicting IBFT message
     * @param msg2 Second conflicting IBFT message
     * @param reason The reason for slashing
     */
    function slashValidator(
        address validator,
        IBFTMessage calldata msg1,
        IBFTMessage calldata msg2,
        string calldata reason
    ) external;

    /**
     * @notice Check if a validator has been slashed
     * @param validator Address of the validator
     * @return True if the validator has been slashed
     */
    function hasBeenSlashed(address validator) external view returns (bool);

    /**
     * @notice Get the evidence hash for a slashed validator
     * @param validator Address of the validator
     * @return The stored evidence hash
     */
    function getEvidenceHash(address validator) external view returns (bytes32);

    /**
     * @notice Set or update BLS contract address
     * @param blsAddr Address of the BLS contract
     */
    function setBLSAddress(address blsAddr) external;
}
