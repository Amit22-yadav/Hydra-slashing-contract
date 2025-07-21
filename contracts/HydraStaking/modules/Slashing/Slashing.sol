// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ISlashing} from "./ISlashing.sol";
import {System} from "../../../common/System/System.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface IInspector {
    function slashValidator(address validator, string calldata reason) external;
}

contract Slashing is ISlashing, System, Initializable {
    // Reference to the HydraChain contract (Inspector module)
    address public hydraChainContract;

    // Initializer for upgradeable pattern
    function initialize(address hydraChainAddr) external initializer onlySystemCall {
        __Slashing_init(hydraChainAddr);
    }

    // Internal initializer function
    function __Slashing_init(address hydraChainAddr) internal onlyInitializing {
        hydraChainContract = hydraChainAddr;
    }

    /**
     * @notice Called by the system to slash a validator for double-signing.
     * @dev On-chain evidence verification is omitted; assumes consensus nodes have already verified.
     * @param validator Address of the validator to be slashed
     * @param reason Reason for slashing (string)
     */
    function slashValidator(address validator, string calldata reason) external onlySystemCall {
        require(validator != address(0), "Invalid validator address");
        // Notify Inspector module on HydraChain
        IInspector(hydraChainContract).slashValidator(validator, reason);
        emit ValidatorSlashed(validator, reason);
    }
}