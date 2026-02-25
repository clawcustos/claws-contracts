// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../src/CustosNetworkProxyV057.sol";

/**
 * @title DeployV057
 * @notice Deploy CustosNetworkProxyV057 impl and propose upgrade via confirmUpgrade (2-of-2 custodian).
 *
 * STEP 1 — Custos deploys impl:
 *   DEPLOYER_KEY=$(cat ~/.config/claws/market-maker-key) \
 *   forge script script/DeployV057.s.sol --rpc-url https://base-mainnet.g.alchemy.com/v2/yl0eEel9mhO_P_ozpzdtZ --broadcast
 *
 * STEP 2 — Custos proposes upgrade:
 *   cast send 0x9B5FD0B02355E954F159F33D7886e4198ee777b9 \
 *     "confirmUpgrade(address)" <NEW_IMPL> \
 *     --private-key $(cat ~/.config/claws/market-maker-key) \
 *     --rpc-url https://base-mainnet.g.alchemy.com/v2/yl0eEel9mhO_P_ozpzdtZ
 *
 * STEP 3 — Pizza confirms (triggers upgrade):
 *   cast send 0x9B5FD0B02355E954F159F33D7886e4198ee777b9 \
 *     "confirmUpgrade(address)" <NEW_IMPL> \
 *     --private-key <PIZZA_KEY> \
 *     --rpc-url https://mainnet.base.org
 *
 * STEP 4 — Verify:
 *   cast call 0x9B5FD0B02355E954F159F33D7886e4198ee777b9 \
 *     "inscriptionBlockType(uint256)" 0 --rpc-url https://mainnet.base.org
 *   → returns "" (empty string for id 0), confirming V057 is live
 *
 * ADDRESSES:
 *   Proxy (canonical):  0x9B5FD0B02355E954F159F33D7886e4198ee777b9
 *   Custos wallet:      0x0528B8FE114020cc895FCf709081Aae2077b9aFE
 *   Pizza wallet:       0xF305c1A154D1d38a7F9889a3cBDC49DD7e26159F
 */
contract DeployV057 is Script {
    address constant PROXY = 0x9B5FD0B02355E954F159F33D7886e4198ee777b9;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(deployerKey);

        CustosNetworkProxyV057 impl = new CustosNetworkProxyV057();
        console.log("V057 impl deployed:", address(impl));
        console.log("Proxy:             ", PROXY);
        console.log("");
        console.log("Next steps:");
        console.log("1. Custos: cast send <PROXY> 'confirmUpgrade(address)' <IMPL> --private-key <CUSTOS_KEY>");
        console.log("2. Pizza:  cast send <PROXY> 'confirmUpgrade(address)' <IMPL> --private-key <PIZZA_KEY>");

        vm.stopBroadcast();
    }
}
