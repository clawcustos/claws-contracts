// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Claws.sol";

/**
 * @title DeployAndSetup
 * @notice Deploys Claws contract and whitelists 37 agents in one transaction batch
 * @dev Run with: forge script script/DeployAndSetup.s.sol:DeployAndSetup --rpc-url $RPC_URL --broadcast --verify -vvvv
 */
contract DeployAndSetup is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address verifier = 0x84622B7dd49CF13688666182FBc708A94cd2D293;
        address treasury = 0x701450B24C2e603c961D4546e364b418a9e021D7; // Waterfall splits contract

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy contract
        Claws claws = new Claws(verifier, treasury);
        console.log("Claws deployed to:", address(claws));
        console.log("VERSION:", claws.VERSION());

        // 2. Whitelist all 37 agents
        string[] memory handles = new string[](37);
        handles[0] = "clawcustos";
        handles[1] = "bankrbot";
        handles[2] = "moltbook";
        handles[3] = "clawdbotatg";
        handles[4] = "clawnch_bot";
        handles[5] = "KellyClaudeAI";
        handles[6] = "starkbotai";
        handles[7] = "moltenagentic";
        handles[8] = "clawdvine";
        handles[9] = "CLAWD_Token";
        handles[10] = "clawcaster";
        handles[11] = "0_x_coral";
        handles[12] = "lobchanai";
        handles[13] = "agentrierxyz";
        handles[14] = "clawditor";
        handles[15] = "moltipedia_ai";
        handles[16] = "solvrbot";
        handles[17] = "ClawdMarket";
        handles[18] = "clawbrawl2026";
        handles[19] = "ConwayResearch";
        handles[20] = "moltxio";
        handles[21] = "moltlaunch";
        handles[22] = "clawmartxyz";
        handles[23] = "moltverse_space";
        handles[24] = "clawcian";
        handles[25] = "clonkbot";
        handles[26] = "emberclawd";
        handles[27] = "tellrbot";
        handles[28] = "FelixCraftAI";
        handles[29] = "Dragon_Bot_Z";
        handles[30] = "ClawshiAI";
        handles[31] = "moltbunker";
        handles[32] = "fomoltapp";
        handles[33] = "mbarrbosa";
        handles[34] = "clawdict";
        handles[35] = "openclawfred";
        handles[36] = "clawbstr";

        claws.setWhitelistedBatch(handles, true);
        console.log("Whitelisted 37 agents");

        vm.stopBroadcast();
    }
}
