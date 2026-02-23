// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../src/CustosNetworkProxyV54.sol";

contract DeployV54Correct is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(deployerKey);
        CustosNetworkProxyV54 impl = new CustosNetworkProxyV54();
        console.log("V5.4 Implementation deployed:", address(impl));
        vm.stopBroadcast();
    }
}
