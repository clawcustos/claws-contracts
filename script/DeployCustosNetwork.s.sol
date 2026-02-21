// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/CustosNetworkImpl.sol";

/**
 * @title DeployCustosNetwork
 * @notice Deploys CustosNetworkImpl behind a UUPS ERC1967 proxy.
 *
 * Usage:
 *   forge script script/DeployCustosNetwork.s.sol \
 *     --rpc-url $BASE_RPC_URL \
 *     --private-key $CUSTOS_AGENT_KEY \
 *     --broadcast --verify
 *
 * Environment:
 *   BASE_RPC_URL         — Base mainnet RPC
 *   CUSTOS_AGENT_KEY     — market-maker wallet private key
 *   GENESIS_CHAIN_HEAD   — V4 final chainHead (bytes32, from getChainHeadByWallet)
 *   GENESIS_CYCLE_COUNT  — V4 final cycleCount (uint256)
 *
 * The deploying wallet (CUSTOS_AGENT_KEY) is NOT a privileged address in the contract.
 * Both custodians (CUSTOS_WALLET + PIZZA_WALLET) are hardcoded constants.
 *
 * Post-deploy checklist:
 *   1. Call registerAgent("Custos") — pays 10 USDC, registers agent #1
 *   2. USDC approve: 0.1 USDC to proxy address (for first inscription)
 *   3. Call inscribe() — verify prevHash = genesisChainHead, cycleCount starts at 1
 *   4. Verify on basescan: both custodians, genesis state, agent registry
 *   5. Update inscribe-cycle.js CUSTOS_NETWORK target to proxy address
 */
contract DeployCustosNetwork is Script {
    function run() external {
        bytes32 genesisChainHead = vm.envBytes32("GENESIS_CHAIN_HEAD");
        uint256 genesisCycleCount = vm.envUint("GENESIS_CYCLE_COUNT");

        vm.startBroadcast();

        // 1. Deploy implementation
        CustosNetworkImpl impl = new CustosNetworkImpl();

        // 2. Encode initializer calldata
        bytes memory initData = abi.encodeWithSelector(
            CustosNetworkImpl.initialize.selector,
            genesisChainHead,
            genesisCycleCount
        );

        // 3. Deploy UUPS proxy pointing at impl
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        vm.stopBroadcast();

        console.log("=== CustosNetwork Proxy Deployed ===");
        console.log("Implementation:", address(impl));
        console.log("Proxy (canonical address):", address(proxy));
        console.log("Genesis chain head:", vm.toString(genesisChainHead));
        console.log("Genesis cycle count:", genesisCycleCount);
        console.log("");
        console.log("Next steps:");
        console.log("1. USDC approve 10 USDC to proxy for registration");
        console.log("2. Call registerAgent(\"Custos\") on proxy");
        console.log("3. USDC approve 0.1 USDC, call inscribe() with prevHash=genesisChainHead");
        console.log("4. Update CUSTOS_NETWORK_V5 env var to:", address(proxy));
    }
}
