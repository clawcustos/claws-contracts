#!/usr/bin/env bash
# deploy-v5.sh — Deploy CustosNetworkImpl (V5) UUPS proxy to Base mainnet
# Run ONLY after Pizza approval. This costs gas and is irreversible.
#
# Usage: bash deploy-v5.sh [--dry-run]
#   --dry-run  : simulate only (no broadcast)
#
# Prerequisites:
#   - CUSTOS_AGENT_KEY set in environment OR ~/.config/claws/market-maker-key
#   - forge installed (foundry)
#   - Base RPC available (Alchemy key in env)
#
set -euo pipefail

DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load key
export CUSTOS_AGENT_KEY="${CUSTOS_AGENT_KEY:-$(cat ~/.config/claws/market-maker-key)}"
export BASE_RPC_URL="https://base-mainnet.g.alchemy.com/v2/yl0eEel9mhO_P_ozpzdtZ"

V4_ADDR="0xd8D08E9A6916A6D84B3ef33Ed66762b807CE20Df"

echo "=== CustosNetwork V5 Deploy Script ==="
echo "Reading genesis state from V4: $V4_ADDR"

# Fetch genesis values from live V4 contract
GENESIS_CYCLE_COUNT=$(cast call "$V4_ADDR" \
  "agentIdByWallet(address)(uint256)" \
  "0x0528B8FE114020cc895FCf709081Aae2077b9aFE" \
  --rpc-url "$BASE_RPC_URL" 2>/dev/null)

# Fetch chainHead for agent wallet
GENESIS_CHAIN_HEAD=$(cast call "$V4_ADDR" \
  "getChainHeadByWallet(address)(bytes32)" \
  "0x0528B8FE114020cc895FCf709081Aae2077b9aFE" \
  --rpc-url "$BASE_RPC_URL" 2>/dev/null)

echo "Genesis cycle count (agentId from V4): $GENESIS_CYCLE_COUNT"
echo "Genesis chain head: $GENESIS_CHAIN_HEAD"

export GENESIS_CHAIN_HEAD
export GENESIS_CYCLE_COUNT

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "=== DRY RUN — simulating only (no broadcast) ==="
  forge script script/DeployCustosNetwork.s.sol \
    --rpc-url "$BASE_RPC_URL" \
    --private-key "$CUSTOS_AGENT_KEY" \
    -vvv
else
  echo ""
  echo "=== LIVE DEPLOY — broadcasting to Base mainnet ==="
  echo "Press Ctrl+C within 5 seconds to abort..."
  sleep 5

  forge script script/DeployCustosNetwork.s.sol \
    --rpc-url "$BASE_RPC_URL" \
    --private-key "$CUSTOS_AGENT_KEY" \
    --broadcast \
    --verify \
    --etherscan-api-key "$(cat ~/.config/claws/basescan-key 2>/dev/null || echo '')" \
    -vvv

  echo ""
  echo "=== Deploy complete ==="
  echo "Post-deploy checklist:"
  echo "1. Copy proxy address from output above"
  echo "2. USDC approve 10 USDC to proxy for agent registration"
  echo "3. Call registerAgent(\"Custos\") on proxy"
  echo "4. USDC approve 0.1 USDC, call inscribe() with prevHash=genesis chain head"
  echo "5. Update CUSTOS_NETWORK_PROXY env var in inscribe-cycle.js environment"
  echo "6. Update TOOLS.md with new proxy address"
  echo "7. Update dashboard /api/network NETWORK_V4 constant to new proxy"
fi
