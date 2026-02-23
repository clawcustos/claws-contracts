// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CustosNetworkImpl.sol";

contract DeployV54Impl is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(deployerKey);
        
        CustosNetworkImpl impl = new CustosNetworkImpl();
        console.log("V5.4 Implementation deployed:", address(impl));
        
        vm.stopBroadcast();
    }
}
