// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ArcAgentGateway} from "../src/ArcAgentGateway.sol";

contract DeployArcAgentGateway is Script {
    function run() external returns (ArcAgentGateway gateway) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        gateway = new ArcAgentGateway();
        vm.stopBroadcast();

        console.log("ArcAgentGateway deployed on Arc Mainnet at:", address(gateway));
    }
}
