// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../src/CustosMineRewards.sol";
import "../src/CustosMineController.sol";

/**
 * @title DeployCustosMine
 * @notice Deploys CustosMineRewards then CustosMineController, wires them together.
 *
 * Deployment order:
 *   1. CustosMineRewards  (controller address unknown yet — set via setController after)
 *   2. CustosMineController (takes rewards address in constructor)
 *   3. CustosMineRewards.setController(controller)
 *   4. CustosMineController.setCustodian(deployer, true)
 *
 * Run:
 *   DEPLOYER_PRIVATE_KEY=<key> forge script script/DeployCustosMine.s.sol:DeployCustosMine \
 *     --rpc-url https://mainnet.base.org --broadcast --verify \
 *     --etherscan-api-key $BASESCAN_API_KEY -vvvv
 */
contract DeployCustosMine is Script {
    // ── Addresses (Base mainnet) ─────────────────────────────────────────────
    address constant CUSTOS_TOKEN    = 0xF3e20293514d775a3149C304820d9E6a6FA29b07;
    address constant CUSTOS_PROXY    = 0x9B5FD0B02355E954F159F33D7886e4198ee777b9;
    address constant WETH            = 0x4200000000000000000000000000000000000006;
    // 0x AllowanceHolder on Base
    address constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    // Tier thresholds (18 decimals)
    uint256 constant TIER1 = 25_000_000 ether;   // 25M $CUSTOS
    uint256 constant TIER2 = 50_000_000 ether;   // 50M $CUSTOS
    uint256 constant TIER3 = 100_000_000 ether;  // 100M $CUSTOS

    function run() external {
        uint256 deployerKey  = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer     = vm.addr(deployerKey);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        address[] memory custodians = new address[](1);
        custodians[0] = deployer;

        // 1. Deploy CustosMineController first (rewards address can be set later via setCustosMineRewards)
        //    Pass address(0) for rewards — wired below via setCustosMineRewards
        CustosMineController controller = new CustosMineController(
            CUSTOS_TOKEN,
            CUSTOS_PROXY,
            address(0),   // custosMineRewards — set below
            deployer,     // oracle (Custos wallet)
            TIER1,
            TIER2,
            TIER3
        );
        console.log("CustosMineController:", address(controller));

        // 2. Deploy CustosMineRewards with real controller address
        CustosMineRewards rewards = new CustosMineRewards(
            deployer,            // owner
            custodians,          // custodians
            deployer,            // oracle (Custos wallet)
            address(controller), // controller — real address
            WETH,
            CUSTOS_TOKEN,
            ALLOWANCE_HOLDER
        );
        console.log("CustosMineRewards:", address(rewards));

        // 3. Wire controller → rewards (owner-only call)
        controller.setCustosMineRewards(address(rewards));
        console.log("Controller wired to rewards");

        // 4. Set custodians on controller
        controller.setCustodian(deployer, true);
        console.log("Custodian set:", deployer);

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("CustosMineRewards:    ", address(rewards));
        console.log("CustosMineController: ", address(controller));
        console.log("");
        console.log("Next steps:");
        console.log("1. Pizza calls setCustodian(<pizza-wallet>, true) on controller");
        console.log("2. Update mine-claws-tech/src/lib/constants.ts with new addresses");
        console.log("3. Update SKILL.md with new controller address");
        console.log("4. Run oracle: node scripts/mine-status.js to verify state");
    }
}
