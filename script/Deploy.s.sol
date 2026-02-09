// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Claws.sol";

contract DeployClaws is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address verifier = 0x84622B7dd49CF13688666182FBc708A94cd2D293;
        address treasury = 0x87C6C2e72d239B769EAc64B096Dbdc0d4fc7BfA6;

        vm.startBroadcast(deployerPrivateKey);

        Claws claws = new Claws(verifier, treasury);

        console.log("Claws deployed to:", address(claws));

        vm.stopBroadcast();
    }
}
