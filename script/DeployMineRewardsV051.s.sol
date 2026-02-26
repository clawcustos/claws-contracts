// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../src/CustosMineRewardsV051.sol";

contract DeployMineRewardsV051 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Base mainnet addresses
        address OWNER            = deployer; // market-maker wallet (0x0528...)
        address PIZZA_CUSTODIAN  = 0xF305c1A154D1d38a7F9889a3cBDC49DD7e26159F;
        address ORACLE           = 0x19eE9D68cA11Fcf3Db49146b88cAE6E746E67F96;
        address CONTROLLER       = 0xe818445e8A04fEC223b0e8B2f47139C42D157099; // CustosMineControllerV051
        address WETH             = 0x4200000000000000000000000000000000000006;
        address CUSTOS_TOKEN     = 0xF3e20293514d775a3149C304820d9E6a6FA29b07;
        address ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734; // 0x AllowanceHolder

        address[] memory custodians = new address[](2);
        custodians[0] = deployer;         // Custos market-maker
        custodians[1] = PIZZA_CUSTODIAN;  // Pizza

        vm.startBroadcast(deployerKey);

        CustosMineRewardsV051 rewards = new CustosMineRewardsV051(
            OWNER,
            custodians,
            ORACLE,
            CONTROLLER,
            WETH,
            CUSTOS_TOKEN,
            ALLOWANCE_HOLDER
        );

        console.log("CustosMineRewardsV051 deployed:", address(rewards));
        console.log("VERSION:", rewards.VERSION());
        console.log("owner:", rewards.owner());
        console.log("controller:", rewards.controller());

        vm.stopBroadcast();
    }
}
