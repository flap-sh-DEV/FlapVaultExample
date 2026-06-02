// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FreeCoinVaultBeaconFactory} from "src/FreeCoinBeacon.sol";

/// @title DeployFreeCoinBeacon
/// @notice Deploys the FreeCoin beacon-backed vault factory to BNB testnet (chainId 97).
/// @dev Usage:
///      forge script script/testnet/bnb/DeployFreeCoinBeacon.s.sol:DeployFreeCoinBeacon \
///          --rpc-url https://bsc-testnet-dataseed.bnbchain.org \
///          --broadcast \
///          --verify \
///          --private-key <PRIVATE_KEY>
contract DeployFreeCoinBeacon is Script {
    function run() external {
        vm.startBroadcast();

        FreeCoinVaultBeaconFactory factory = new FreeCoinVaultBeaconFactory();

        console.log("FreeCoinVaultBeaconFactory deployed at:", address(factory));
        console.log("UpgradeableBeacon deployed at:      ", factory.beacon());
        console.log("Beacon implementation deployed at:  ", factory.beaconImplementation());

        vm.stopBroadcast();
    }
}

