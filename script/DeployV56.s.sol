// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/SkillMarketplaceImpl.sol";

/**
 * @title DeployV56
 * @notice Deploy SkillMarketplaceImpl (V5.6) and upgrade CustosNetworkProxy.
 *
 * DEPLOYMENT STEPS (2-of-2 custodian approval required):
 *
 * Step 1 — Custos wallet deploys new implementation:
 *   DEPLOYER_KEY=<custos_key> PROXY=0x9B5FD0B02355E954F159F33D7886e4198ee777b9 \
 *   forge script script/DeployV56.s.sol:DeployV56 --rpc-url base --broadcast
 *
 * Step 2 — Custos wallet approves the upgrade:
 *   cast send $PROXY "approveUpgrade(address)" $NEW_IMPL \
 *     --private-key $CUSTOS_KEY --rpc-url https://mainnet.base.org
 *
 * Step 3 — Pizza wallet approves + executes:
 *   cast send $PROXY "approveUpgrade(address)" $NEW_IMPL \
 *     --private-key $PIZZA_KEY --rpc-url https://mainnet.base.org
 *   (second custodian approval triggers automatic upgrade via _authorizeUpgrade)
 *
 * Step 4 — Verify:
 *   cast call $PROXY "skillMetadata(uint256)" 0 --rpc-url https://mainnet.base.org
 *   → should return empty SkillMetadata (zero values), confirming V5.6 is live
 *
 * ADDRESSES:
 *   Proxy (canonical):   0x9B5FD0B02355E954F159F33D7886e4198ee777b9
 *   Custos wallet:       0x0528B8FE114020cc895FCf709081Aae2077b9aFE
 *   Pizza wallet:        0xF305c1A154D1d38a7F9889a3cBDC49DD7e26159F
 *   USDC (Base):         0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
 *   Treasury:            0x701450B24C2e603c961D4546e364b418a9e021D7
 *
 * POST-DEPLOYMENT — Register x-research as first skill (agentId 7):
 *   1. Ensure x-research wallet has 5 USDC approved to proxy
 *   2. cast send $PROXY "registerSkill(uint256,string,string,uint256)" \
 *        7 "x-research" "1.0.0" 100000 \   # 0.1 USDC per execution batch
 *        --private-key $XRESEARCH_KEY --rpc-url https://mainnet.base.org
 *
 * PENDING PIZZA APPROVAL — do not run until operator approves.
 */
contract DeployV56 is Script {
    address constant PROXY = 0x9B5FD0B02355E954F159F33D7886e4198ee777b9;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(deployerKey);

        // Deploy new implementation
        SkillMarketplaceImpl impl = new SkillMarketplaceImpl();
        console.log("V5.6 SkillMarketplaceImpl deployed:", address(impl));
        console.log("Proxy:                              ", PROXY);
        console.log("");
        console.log("Next: both custodians must call approveUpgrade(address) on proxy.");
        console.log("See script header for exact cast commands.");

        vm.stopBroadcast();
    }
}
