// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;
import "forge-std/Script.sol";
import "../src/CustosMineControllerV051.sol";

contract DeployMineV051 is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        address mineRewards = vm.envAddress("MINE_REWARDS_ADDR");
        vm.startBroadcast(key);
        new CustosMineControllerV051(
            0xF3e20293514d775a3149C304820d9E6a6FA29b07,  // CUSTOS_TOKEN
            0x9B5FD0B02355E954F159F33D7886e4198ee777b9,  // CUSTOS_PROXY
            mineRewards,                                  // CustosMineRewards
            0x19eE9D68cA11Fcf3Db49146b88cAE6E746E67F96,  // oracle
            25_000_000e18,                                // tier1
            50_000_000e18,                                // tier2
            100_000_000e18                                // tier3
        );
        vm.stopBroadcast();
    }
}
