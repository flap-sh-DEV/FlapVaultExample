// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FreeCoinVaultFactory} from "../../../src/FreeCoin.sol";
import {FlapDeployed} from "../../../src/FlapDeployed.sol";
import {IVaultPortal, IVaultPortalTypes} from "../../../src/flap/IVaultPortal.sol";

/// @title DeployFreeCoin
/// @notice Deploys the FreeCoinVaultFactory to BNB mainnet (chainId 56)
///         and registers it with the VaultPortal.
/// @dev Usage: forge script script/mainnet/bnb/DeployFreeCoin.s.sol:DeployFreeCoin --rpc-url https://bsc-dataseed.bnbchain.org --broadcast --verify --private-key <PRIVATE_KEY>
contract DeployFreeCoin is Script {
    function run() external {
        vm.startBroadcast();

        // 1. Deploy FreeCoinVaultFactory
        FreeCoinVaultFactory factory = new FreeCoinVaultFactory();
        console.log("FreeCoinVaultFactory deployed at:", address(factory));

        vm.stopBroadcast();
    }
}
