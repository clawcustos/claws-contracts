// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;
import "forge-std/Script.sol";
import "../src/CustosMineControllerV3.sol";

contract DeployMineV3 is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(key);
        new CustosMineControllerV3(
            0xF3e20293514d775a3149C304820d9E6a6FA29b07,  // CUSTOS_TOKEN
            0x9B5FD0B02355E954F159F33D7886e4198ee777b9,  // CUSTOS_PROXY (v0.5.7 live)
            0x43fB5616A1b4Df2856dea2EC4A3381189d5439e7,  // MineRewards (reuse existing)
            0x0528B8FE114020cc895FCf709081Aae2077b9aFE,  // oracle = Custos wallet
            25_000_000e18,                               // tier1: 25M CUSTOS
            50_000_000e18,                               // tier2: 50M CUSTOS
            100_000_000e18                               // tier3: 100M CUSTOS
        );
        vm.stopBroadcast();
    }
}
