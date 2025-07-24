// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Staking} from "../../../contracts/HydraStaking/Staking.sol";

abstract contract TestStaking is Staking {
    function initialize(
        uint256 newMinStake,
        address governance,
        address aprCalculatorAddr,
        address hydraChainAddr,
        address rewardWalletAddr
    ) external initializer {
        __Staking_init(newMinStake, governance, aprCalculatorAddr, hydraChainAddr, rewardWalletAddr);
    }
}
