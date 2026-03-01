// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CustosMineControllerV053.sol";

contract DeployMineV053 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        address deployer          = vm.addr(pk);
        address PIZZA_CUSTODIAN   = 0xF305c1A154D1d38a7F9889a3cBDC49DD7e26159F;
        address ORACLE            = 0x19eE9D68cA11Fcf3Db49146b88cAE6E746E67F96;
        address CUSTOS_TOKEN      = 0xF3e20293514d775a3149C304820d9E6a6FA29b07;
        address CUSTOS_PROXY      = 0x9B5FD0B02355E954F159F33D7886e4198ee777b9;
        address MINE_REWARDS      = 0x49593d90e3279A829436A46cD9f213e1A89836b4;

        CustosMineControllerV053 controller = new CustosMineControllerV053(
            CUSTOS_TOKEN,
            CUSTOS_PROXY,
            MINE_REWARDS,
            ORACLE,
            25_000_000 ether,
            50_000_000 ether,
            100_000_000 ether
        );

        controller.setCustodian(PIZZA_CUSTODIAN, true);
        controller.setCustodian(deployer, true);

        vm.stopBroadcast();

        console.log("V053 deployed at:", address(controller));
        console.log("Owner:", deployer);
        console.log("Oracle:", ORACLE);
        console.log("MineRewards:", MINE_REWARDS);
        console.log("");
        console.log("Post-deploy checklist:");
        console.log("  1. depositRewards() or allocateRewards() to fund reward buffer");
        console.log("  2. Update oracle to point at new contract address");
        console.log("  3. Update ABIs in custos-mine/abi.js and mine-claws-tech-3d");
        console.log("  4. Re-stake agents on new contract");
    }
}
