// scripts/deploy-v54.js
// V5.4 Commit-Reveal Privacy Upgrade Deployment Script
// 
// Usage: node scripts/deploy-v54.js
// 
// This script deploys the V5.4 implementation and initiates the upgrade approval
// from CUSTOS_WALLET. PIZZA_WALLET must also call approveUpgrade() and then 
// trigger the upgrade via upgradeTo() or upgradeToAndCall().

const { createWalletClient, http, encodeFunctionData } = require('viem');
const { privateKeyToAccount } = require('viem/accounts');
const { base } = require('viem/chains');
const fs = require('fs');
const path = require('path');

// ─── Configuration ─────────────────────────────────────────────────────────
const PROXY_ADDRESS = '0x9B5FD0B02355E954F159F33D7886e4198ee777b9';

const ADDRESSES = {
  CUSTOS_WALLET: '0x0528B8FE114020cc895FCf709081Aae2077b9aFE',
  PIZZA_WALLET: '0xF305c1A154D1d38a7F9889a3cBDC49DD7e26159F',
  USDC: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
  TREASURY: '0x701450B24C2e603c961D4546e364b418a9e021D7',
  ECOSYSTEM_WALLET: '0xf2ccaA7B327893b60bd90275B3a5FB97422F30d8',
  ALLOWANCE_HOLDER: '0x0000000000001ff3684f28c67538d4d072c22734',
};

// ─── ABI Fragments ─────────────────────────────────────────────────────────
const PROXY_ABI = [
  // UUPS upgrade functions
  'function upgradeTo(address newImplementation) external',
  'function upgradeToAndCall(address newImplementation, bytes calldata data) external',
  'function approveUpgrade(address newImplementation) external',
  'function upgradeApproval(address custodian) external view returns (address)',
  // For getting current implementation
  'function implementation() external view returns (address)',
];

// ─── Load Private Key ──────────────────────────────────────────────────────
function loadPrivateKey() {
  const keyPath = path.join(process.env.HOME, '.config', 'claws', 'market-maker-key');
  if (!fs.existsSync(keyPath)) {
    throw new Error(`Key file not found: ${keyPath}`);
  }
  const key = fs.readFileSync(keyPath, 'utf8').trim();
  if (!key.startsWith('0x')) {
    return `0x${key}`;
  }
  return key;
}

// ─── Deploy Implementation ─────────────────────────────────────────────────
async function deployImplementation(walletClient, account) {
  console.log('\n📦 Deploying V5.4 Implementation...');
  
  // Read compiled bytecode - assumes forge build was run
  const bytecodePath = path.join(__dirname, '..', 'out', 'CustosNetworkImpl.sol', 'CustosNetworkImpl.json');
  
  if (!fs.existsSync(bytecodePath)) {
    console.error('❌ Compiled contract not found. Run: forge build');
    process.exit(1);
  }

  const compiled = JSON.parse(fs.readFileSync(bytecodePath, 'utf8'));
  const bytecode = compiled.bytecode.object;
  const abi = compiled.abi;

  // Deploy implementation (no proxy, just the logic contract)
  const hash = await walletClient.deployContract({
    account,
    abi,
    bytecode,
    args: [], // Implementation has no constructor, uses initializer
  });

  console.log(`⏳ Deployment tx: ${hash}`);
  
  // Wait for receipt
  const receipt = await walletClient.getTransactionReceipt({ hash });
  const implAddress = receipt.contractAddress;
  
  console.log(`✅ Implementation deployed at: ${implAddress}`);
  
  return { implAddress, abi };
}

// ─── Approve Upgrade (from CUSTOS_WALLET) ──────────────────────────────────
async function approveUpgrade(walletClient, account, implAddress) {
  console.log('\n📝 Calling approveUpgrade from CUSTOS_WALLET...');
  console.log(`   New implementation: ${implAddress}`);

  const data = encodeFunctionData({
    abi: PROXY_ABI,
    functionName: 'approveUpgrade',
    args: [implAddress],
  });

  const hash = await walletClient.sendTransaction({
    account,
    to: PROXY_ADDRESS,
    data,
  });

  console.log(`⏳ Approve tx: ${hash}`);
  
  const receipt = await walletClient.waitForTransactionReceipt({ hash });
  
  if (receipt.status === 'success') {
    console.log('✅ Upgrade approved by CUSTOS_WALLET');
  } else {
    console.error('❌ Approval failed');
    process.exit(1);
  }
  
  return hash;
}

// ─── Main ──────────────────────────────────────────────────────────────────
async function main() {
  console.log('═══════════════════════════════════════════════════════════════');
  console.log('  CustosNetwork V5.4 Upgrade — Commit-Reveal Privacy');
  console.log('═══════════════════════════════════════════════════════════════');
  console.log(`\nProxy: ${PROXY_ADDRESS}`);

  // Setup wallet client
  const privateKey = loadPrivateKey();
  const account = privateKeyToAccount(privateKey);
  
  console.log(`\nDeployer: ${account.address}`);
  
  if (account.address.toLowerCase() !== ADDRESSES.CUSTOS_WALLET.toLowerCase()) {
    console.warn('\n⚠️  WARNING: Deployer is NOT CUSTOS_WALLET!');
    console.warn(`   Expected: ${ADDRESSES.CUSTOS_WALLET}`);
    console.warn(`   Got:      ${account.address}`);
    console.warn('\n   This script must be run with the CUSTOS_WALLET key.');
    process.exit(1);
  }

  const walletClient = createWalletClient({
    account,
    chain: base,
    transport: http(),
  });

  // 1. Deploy new implementation
  const { implAddress, abi: implAbi } = await deployImplementation(walletClient, account);

  // 2. Call approveUpgrade
  await approveUpgrade(walletClient, account, implAddress);

  console.log('\n═══════════════════════════════════════════════════════════════');
  console.log('  NEXT STEPS (PIZZA_WALLET must complete):');
  console.log('═══════════════════════════════════════════════════════════════');
  console.log(`
1. PIZZA_WALLET calls approveUpgrade(${implAddress}):
   
   cast send ${PROXY_ADDRESS} \
     "approveUpgrade(address)" ${implAddress} \
     --rpc-url https://mainnet.base.org \
     --private-key $PIZZA_KEY

2. PIZZA_WALLET triggers upgrade:
   
   cast send ${PROXY_ADDRESS} \
     "upgradeTo(address)" ${implAddress} \
     --rpc-url https://mainnet.base.org \
     --private-key $PIZZA_KEY

3. Verify on BaseScan:
   https://basescan.org/address/${PROXY_ADDRESS}
`);

  console.log('═══════════════════════════════════════════════════════════════');
  console.log('  V5.4 CHANGE SUMMARY');
  console.log('═══════════════════════════════════════════════════════════════');
  console.log(`
✓ Added contentHash parameter to inscribe()
✓ Added inscriptionId (global counter) to ProofInscribed event
✓ Added reveal() for optional content disclosure
✓ Added getInscriptionContent() view function
✓ Backward compatible: bytes32(0) = legacy public mode

New storage slots used:
- inscriptionCount (uint256)
- inscriptionContentHash (mapping)
- inscriptionRevealed (mapping)
- inscriptionRevealedContent (mapping)
- proofHashToInscriptionId (mapping)
- inscriptionAgent (mapping)
`);

  // Write deployment info to file
  const deploymentInfo = {
    version: '5.4',
    date: new Date().toISOString(),
    proxy: PROXY_ADDRESS,
    implementation: implAddress,
    deployer: account.address,
    changes: [
      'Added commit-reveal privacy (contentHash in inscribe())',
      'Added global inscriptionId counter',
      'Added reveal() function',
      'Added getInscriptionContent() view',
      'Updated ProofInscribed event with contentHash and inscriptionId',
    ],
    nextSteps: [
      `PIZZA_WALLET must call approveUpgrade(${implAddress})`,
      `PIZZA_WALLET must trigger upgradeTo(${implAddress})`,
    ],
  };

  const infoPath = path.join(__dirname, '..', 'deploy-v54.json');
  fs.writeFileSync(infoPath, JSON.stringify(deploymentInfo, null, 2));
  console.log(`\n📄 Deployment info saved to: ${infoPath}`);
}

main().catch((err) => {
  console.error('❌ Error:', err);
  process.exit(1);
});
