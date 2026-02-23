// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;
import "forge-std/Script.sol";
import "../src/CustosNetworkProxyV55.sol";

contract DeployV55 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(deployerKey);
        CustosNetworkProxyV55 impl = new CustosNetworkProxyV55();
        console.log("V5.5 Implementation deployed:", address(impl));
        vm.stopBroadcast();
    }
}
