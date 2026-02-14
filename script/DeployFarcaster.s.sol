// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/ClawsFarcaster.sol";

/**
 * @title DeployFarcaster
 * @notice Deploys ClawsFarcaster contract to Base
 * @dev Run with: forge script script/DeployFarcaster.s.sol:DeployFarcaster --rpc-url $RPC_URL --broadcast --verify -vvvv
 */
contract DeployFarcaster is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Same verifier and treasury as the X contract
        address verifier = 0x84622B7dd49CF13688666182FBc708A94cd2D293;
        address treasury = 0x701450B24C2e603c961D4546e364b418a9e021D7;

        vm.startBroadcast(deployerPrivateKey);

        ClawsFarcaster claws = new ClawsFarcaster(verifier, treasury);

        console.log("ClawsFarcaster deployed to:", address(claws));
        console.log("VERSION:", claws.VERSION());
        console.log("Verifier:", verifier);
        console.log("Treasury:", treasury);

        vm.stopBroadcast();
    }
}
