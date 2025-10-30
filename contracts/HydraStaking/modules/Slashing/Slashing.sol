// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ISlashing, IBFTMessage} from "./ISlashing.sol";
import {System} from "../../../common/System/System.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IInspector} from "../../../HydraChain/modules/Inspector/IInspector.sol";
import {IBLS} from "../../../BLS/IBLS.sol";

// Extend with interface for pubkey access if needed
interface IInspectorWithPubkey {
    function getValidatorPubkey(address validator) external view returns (uint256[4] memory);
}

contract Slashing is ISlashing, System, Initializable {
    IBLS public bls;
    // Reference to the HydraChain contract (Inspector module)
    address public hydraChainContract;

    // Set or update BLS contract address (for upgradeable pattern)
    function setBLSAddress(address blsAddr) external onlySystemCall {
        bls = IBLS(blsAddr);
    }

    // Initializer for upgradeable pattern
    function initialize(address hydraChainAddr) external initializer onlySystemCall {
        slashingInit(hydraChainAddr);
    }

    // Internal initializer function
    function slashingInit(address hydraChainAddr) internal onlyInitializing {
        hydraChainContract = hydraChainAddr;
    }

    // Add custom errors at the top
    error InvalidValidatorAddress();

    /**
     * @notice Called by the system to slash a validator for double-signing.
     * @dev On-chain evidence verification is omitted; assumes consensus nodes have already verified.
     * @param validator Address of the validator to be slashed
     * @param reason Reason for slashing (string)
     */
    function slashValidator(
        address validator,
        IBFTMessage calldata msg1,
        IBFTMessage calldata msg2,
        string calldata reason
    ) external onlySystemCall {
        if (validator == address(0)) revert InvalidValidatorAddress();
        require(msg1.from == validator && msg2.from == validator, "Evidence: from != validator");
        require(msg1.height == msg2.height, "Evidence: height mismatch");
        require(msg1.round == msg2.round, "Evidence: round mismatch");
        require(msg1.msgType == msg2.msgType, "Evidence: type mismatch");
        require(keccak256(msg1.signature) != keccak256(msg2.signature), "Evidence: identical messages");
        require(address(bls) != address(0), "BLS address not set");
        uint256[4] memory pubkey = IInspectorWithPubkey(hydraChainContract).getValidatorPubkey(validator);

        // Decode BLS signatures from bytes
        uint256[2] memory sig1 = abi.decode(msg1.signature, (uint256[2]));
        uint256[2] memory sig2 = abi.decode(msg2.signature, (uint256[2]));

        // Hash the message data and convert to uint256[2] for BLS verification
        bytes32 msg1datahash = keccak256(msg1.data);
        bytes32 msg2datahash = keccak256(msg2.data);
        uint256[2] memory msg1ForBLS = [uint256(msg1datahash), 0];
        uint256[2] memory msg2ForBLS = [uint256(msg2datahash), 0];

        // Verify BLS signatures
        (bool ok1,) = bls.verifySingle(sig1, pubkey, msg1ForBLS);
        require(ok1, "Evidence: msg1 signature invalid");
        (bool ok2,) = bls.verifySingle(sig2, pubkey, msg2ForBLS);
        require(ok2, "Evidence: msg2 signature invalid");
        IInspector(hydraChainContract).slashValidator(validator, reason);
        emit ValidatorSlashed(validator, reason);
        // emit DoubleSignEvidence(validator, keccak256(msg1.data), keccak256(msg2.data));
    }
}
