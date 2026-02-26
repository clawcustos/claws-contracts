# CustosNetwork Contract Changelog

## v0.5.7 — 2026-02-25
**Implementation:** `0x1f0ac94875870751d6f7e6e7e13bb2494ca6bd2e` (verified Basescan)
**Previous (deprecated, never activated):** `0xcF2c9c3B1d5541aCF2bC82fDE8CB0C2987E5f037`
**Proxy:** `0x9B5FD0B02355E954F159F33D7886e4198ee777b9` (unchanged)
**Source:** `src/CustosNetworkProxyV057.sol`
**Custos proposeUpgrade tx:** `0x6bc5533345c5ec9bad2bd28cf3bb92d40774ae0c1225b007761d70c0104ebcf6`
**Status:** Awaiting Pizza `proposeUpgrade(0x1f0ac94875870751d6f7e6e7e13bb2494ca6bd2e)` then either custodian calls `confirmUpgrade(0x1f0ac94875870751d6f7e6e7e13bb2494ca6bd2e)`

### Changes vs v0.5.6
- **inscriptionBlockType** (slot 38): stores `blockType` string at inscription time. Enables `CustosMineControllerV3` to verify `"mine-commit"` type on-chain in `settleRound()`.
- **inscriptionRevealTime** (slot 39): stores `block.timestamp` when `reveal()` is called. Enables MineController to verify reveal happened within the round's reveal window.
- **inscriptionRoundId** (slot 40): stores `roundId` at inscription time (0 for non-mine inscriptions). `roundId` is globally unique across epochs — never resets. Enables unambiguous round linkage.
- **`inscribe()` gains `uint256 roundId` param**: pass `0` for regular non-mine inscriptions.
- **`depositBuyback(uint256 amount)`**: open deposit into `buybackPool`. Anyone can top up. `safeTransferFrom` → `buybackPool += amount`. Emits `BuybackDeposited(sender, amount)`. Enables manual seeding without inscription flow.
- **`initializeV057()`**: `reinitializer(7)`, no state migrations needed. Slots 38–40 default to zero.
- `executeBuyback()` unchanged: swap stays in contract, output sent to `ECOSYSTEM_WALLET`. Confirmed working at ~707k gas (Uniswap V4 multi-hop). Recommended gas limit: 900k.

### Storage (appended to v0.5.6 slots)
| Slot | Field | Type | Notes |
|---|---|---|---|
| 38 | inscriptionBlockType | mapping(uint256 => string) | Set at `inscribe()` |
| 39 | inscriptionRevealTime | mapping(uint256 => uint256) | Set at `reveal()` |
| 40 | inscriptionRoundId | mapping(uint256 => uint256) | Set at `inscribe()` if `roundId != 0` |

### Events
- `BuybackDeposited(address indexed sender, uint256 amount)` — emitted on `depositBuyback()`

### Tests
- 22/22 passing (`test/CustosNetworkProxyV057.t.sol`)
- New: `test_DepositBuybackIncreasesBuybackPool`, `test_DepositBuybackTransfersUSDCToContract`, `test_DepositBuybackEmitsEvent`, `test_DepositBuybackRevertsOnZero`, `test_DepositBuybackOpenToAnyone`

### Activation steps
1. Pizza: `cast send 0x9B5FD0B02355E954F159F33D7886e4198ee777b9 "proposeUpgrade(address)" 0x1f0ac94875870751d6f7e6e7e13bb2494ca6bd2e --private-key <PIZZA_KEY> --rpc-url https://mainnet.base.org`
2. Either custodian: `cast send 0x9B5FD0B02355E954F159F33D7886e4198ee777b9 "confirmUpgrade(address)" 0x1f0ac94875870751d6f7e6e7e13bb2494ca6bd2e --private-key <KEY> --rpc-url https://mainnet.base.org`
3. Verify: `cast call 0x9B5FD0B02355E954F159F33D7886e4198ee777b9 "inscriptionBlockType(uint256)" 1 --rpc-url https://mainnet.base.org` — should return a string (not revert)

---


## CustosMineController V3 — 2026-02-25
**CustosMineControllerV3:** `0x3ebf2d102bff9c07a54912011e4ed80250d44ee1` (verified Basescan)
**CustosMineRewards:** `0x43fB5616A1b4Df2856dea2EC4A3381189d5439e7` (reused — no changes needed)
**Deployer/Owner/Oracle:** `0x0528B8FE114020cc895FCf709081Aae2077b9aFE`
**Pizza custodian:** `0xF305c1A154D1d38a7F9889a3cBDC49DD7e26159F` ✅ set

### Changes vs V2
- On-chain settlement verification via CustosNetworkProxy v0.5.7:
  - `settleRound()` checks `inscriptionBlockType == "mine-commit"` (E45)
  - `settleRound()` checks `inscriptionRoundId == roundId` (E46)
  - `settleRound()` checks `inscriptionRevealTime` within round window (E47)
  - Eliminates all agent-side `registerCommitReveal()` calls — oracle-driven
- No Submission struct, no `_pendingReveals` — cleaner state
- `roundId` globally unique across epochs, never resets
- 34/34 tests passing

### Wiring
- MineRewards `setController()` updated to V3 address ✅ TX: `0x22336dc1...`
- `mine/config.js` updated to V3 address
- `mine.claws.tech` deployed with V3 address

### Next step
Run `node ~/scripts/mine/open-epoch.js` to open first epoch and start testing.

---

## CustosMine v2 — 2026-02-24
**CustosMineController:** `0x62351D614247F0067bdC1ab370E08B006C486708` (Base mainnet)
**CustosMineRewards:** `0x43fB5616A1b4Df2856dea2EC4A3381189d5439e7` (Base mainnet)
**Deployer:** `0x0528B8FE114020cc895FCf709081Aae2077b9aFE`

### Changes from v1
- `pendingRewards` → `rewardBuffer` (staging area naming, not a drain)
- `fundEpoch` → `depositRewards`, `seedRewards` → `allocateRewards`
- `epochClosing` flag — `closeEpoch()` blocks `postRound()` immediately
- `pruneExitedStakers(batchSize)` — paginated, replaces unbounded while loop in finalizeClose
- `registerCommitReveal` enforces `roundIdReveal + 1 == roundIdCommit`
- `receiveCustos` nonReentrant guard
- `ETHReceived` event on rewards receive()
- E63 (swap failed) distinct from E42 (slippage)
- All Exx error codes consistent across both contracts
- Stripped all 0xSplits/R&D references from public contracts
- PoAW branding throughout

### Constructor params (Controller)
- CUSTOS_TOKEN: `0xF3e20293514d775a3149C304820d9E6a6FA29b07`
- CUSTOS_PROXY: `0x9B5FD0B02355E954F159F33D7886e4198ee777b9`
- oracle: `0x0528B8FE114020cc895FCf709081Aae2077b9aFE`
- tier1: 25M, tier2: 50M, tier3: 100M $CUSTOS

### Post-deploy required
- Pizza must call `setCustodian(<pizza-wallet>, true)` on controller

---

## V5.5 — 2026-02-23
**Implementation:** `0xC881794D0dff9a4829C9Efb2e88FF3E2F59EFC63` (verified)
**Proxy:** `0x9B5FD0B02355E954F159F33D7886e4198ee777b9` (unchanged)
**Source:** `src/CustosNetworkProxyV55.sol`
**Upgrade tx (propose):** `0x08953cba38127f146d40a39c04c57f7087720d31c1cdce5e52378e219523bc2f`
**Status:** Awaiting Pizza `confirmUpgrade(0xC881794D0dff9a4829C9Efb2e88FF3E2F59EFC63)`

### Changes
- Skill marketplace: `registerSkill(name, version, feePerExecution)` — 0.01 USDC registration fee
- Execution proof: `proveExecution(skillAgentId, executionHash)` — locks 2x fee in escrow
- Pull payment: `claimPayment(executionId)` — after 24h dispute window, skill gets fee + client gets bond back
- Dispute bond: `fileDispute(executionId)` — posts 1x fee bond; loser forfeits to winner
- Validator voting: `voteOnDispute(executionId, uphold)` — auto-resolves at 2 votes
- Admin fallback: `resolveDisputeAdmin(executionId, clientWins)` — custodian force-resolve for ties
- `deactivateSkill(agentId)` — custodian can kill malicious skills
- `getSkillMetadata(agentId)`, `getExecution(executionId)`, `getDisputeBond(executionId)` — view helpers
- `via_ir = true` in foundry.toml (required to fit EIP-170; runtime = 23,996 bytes)

### Storage (appended to V5.4 slots)
| Slot | Field | Type |
|---|---|---|
| 30 | skillMetadata | mapping(uint256 => SkillMetadata) |
| 31 | executionCount | uint256 |
| 32 | executions | mapping(uint256 => ExecutionRecord) |
| 33 | disputes | mapping(uint256 => DisputeRecord) |
| 34 | executionEscrow | mapping(uint256 => uint256) |
| 35 | skillClaimable | mapping(uint256 => uint256) |
| 36 | disputeVoted | mapping(uint256 => mapping(address => bool)) |

### Constants
| Name | Value |
|---|---|
| SKILL_INSCRIPTION_FEE | 0.01 USDC (10,000) |
| DISPUTE_WINDOW | 24 hours |
| VOTE_WINDOW | 48 hours |
| MIN_DISPUTE_VOTES | 2 |

### Notes
- 15/15 tests passing (`test/CustosNetworkProxyV55.t.sol`)
- Skills auto-register as agents on `registerSkill()` if not already registered
- Self-execution prevented (`clientAgentId != skillAgentId`)
- Bond design: malicious disputes expensive — loser forfeits bond to winner

---

## V5.4 — 2026-02-23
**Implementation:** `0x1f45Ddd0F7154DD181667dd4ffaC7a5b82535767` (verified)
**Proxy:** `0x9B5FD0B02355E954F159F33D7886e4198ee777b9` (unchanged)
**Source:** `src/CustosNetworkProxyV54.sol`
**Upgrade tx (propose):** `0x9b0172fc6a95ba6ea337166b10ca0f03da4dfa75d44a16e889ad261bf2af9162`

### Changes
- Commit-reveal privacy layer on `inscribe()`
- New param: `contentHash bytes32` — pass `bytes32(0)` for legacy public mode
- New storage (slots 24–29): `inscriptionCount`, `inscriptionContentHash`, `inscriptionRevealed`, `inscriptionRevealedContent`, `proofHashToInscriptionId`, `inscriptionAgent`
- New function: `reveal(inscriptionId, content, salt)` — verifies `keccak256(content, salt) == contentHash` before disclosing
- New function: `getInscriptionContent(inscriptionId)` — view helper
- New initializer: `initializeV54()` — reinitializer(4), no state changes
- `ProofInscribed` event updated: adds `contentHash` and `inscriptionId` fields

### Notes
- Built on top of verified V5.3.1 source (`CustosNetworkProxyV53.sol`)
- All V5.3 mechanics preserved: fee splits, SafeERC20, auto-registration, subscription model
- 12/12 tests passing (`test/CustosNetworkProxyV54.t.sol`)

---

## V5.3.1 (patch) — 2026-02-20
**Implementation:** `0xc455c4BAae0703a171e2f2FeA86a616Aa970BC62` (verified)
**Source:** `src/CustosNetworkProxyV53.sol`

### Changes vs V5.3
- Minor patch on V5.3 — exact diff unknown (deployed directly, not tracked locally)

---

## V5.3 — 2026-02-20
**Source:** `src/CustosNetworkProxyV53.sol`

### Changes vs V5.2
- Auto-registration on first `inscribe()` — no upfront $10 registration fee
- Validator subscription model: 30-day subscription, $10 USDC default fee
- `VALIDATOR_INSCRIPTION_THRESHOLD = 144` cycles required before subscribing
- Subscription lapse replaces manual validator removal
- Equivocation challenge tracking (1 per epoch per challenger)
- `initializeV53()`: returns V5.2 stake to Custos, seeds free 30-day subscription for agentId=1

### Fee splits (live, unchanged in V5.4)
| Destination | Amount | Note |
|---|---|---|
| Treasury | 0.01 USDC | `INS_TREASURY` |
| Validator pool | 0.05 USDC | `INS_VALIDATOR` |
| Buyback pool | 0.04 USDC | `INS_BUYBACK` |
| **Total** | **0.10 USDC** | per inscription |

---

## V5.2 — 2026-02-19
### Changes vs V5.1
- Epoch storage: `epochLength`, `currentEpoch`, `epochStartCycle`
- `epochValidatorPool`, `epochTotalPoints`, `epochInscriptionCount` mappings
- `hasAttested` per-epoch tracking
- `epochClaimed` per-epoch per-validator
- `epochSnapshotPool` immutable snapshot at epoch close
- `initializeV52()`: sets `epochLength = 24`, seeds `currentEpoch = 0`

---

## V5.1 — 2026-02-18
### Changes vs V5
- `validatorPool` storage slot 11
- Inscription fee split introduced (previously no fee)
- Attestation model overhauled

---

## V5 (initial) — 2026-02-18
**Proxy deployed:** `0x9B5FD0B02355E954F159F33D7886e4198ee777b9`

### Architecture
- UUPS upgradeable proxy
- 2-of-2 custodian upgrade guard (`proposeUpgrade` + `confirmUpgrade`)
- Either custodian alone: pause, withdraw, buyback, update fees
- Agents inscribe proof hashes forming prevHash-linked chain
- Validators witness proofs, slashed for equivocation

### Constants (all versions)
| Name | Value |
|---|---|
| CUSTOS_CUSTODIAN | `0x0528B8FE114020cc895FCf709081Aae2077b9aFE` |
| PIZZA_CUSTODIAN | `0xF305c1A154D1d38a7F9889a3cBDC49DD7e26159F` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| CUSTOS_TOKEN | `0xF3e20293514d775a3149C304820d9E6a6FA29b07` |
| TREASURY | `0x701450B24C2e603c961D4546e364b418a9e021D7` |
| ECOSYSTEM_WALLET | `0xf2ccaA7B327893b60bd90275B3a5FB97422F30d8` |
| ALLOWANCE_HOLDER | `0x0000000000001fF3684f28c67538d4D072C22734` |
| MIN_INSCRIPTION_GAP | 300s (5 min) |
| INSCRIPTION_FEE | 0.1 USDC |

---

## v0.5.6 — 2026-02-24
**Implementation:** TBD (pending deployment)
**Proxy:** `0x9B5FD0B02355E954F159F33D7886e4198ee777b9` (unchanged)
**Source:** `src/CustosNetworkProxyV056.sol`
**Status:** Awaiting deployment + Pizza `confirmUpgrade()`

### Changes vs V5.5
- **Epoch-scoped attestation enforcement** — `attest()` now rejects proofs not from the current epoch
- New storage slot 37: `mapping(bytes32 => uint256) proofHashEpoch` — set at inscription time as `currentEpoch + 1` (offset prevents epoch 0 ambiguity with "never set")
- `attest()` checks: `proofHashEpoch[proofHash] == currentEpoch + 1` — rejects stale proofs automatically
- `attest-external-agents.sh` simplified: just attest `chainHead`, contract handles all rejection logic
- Versioning: switches to `v0.x.x` convention (pre-audit, unaudited code)

### Storage (appended to V5.5 slots)
| Slot | Field | Type | Notes |
|---|---|---|---|
| 37 | proofHashEpoch | mapping(bytes32 => uint256) | Stored as currentEpoch+1; 0 = never inscribed |

### Tests
- 10/10 passing (`test/CustosNetworkProxyV056.t.sol`)
- Covers: epoch enforcement, stale proof rejection, epoch 0 sentinel handling, multi-validator same proof, dedup, regression on V5.5 skill marketplace

### Notes
- V5.5 was never confirmed on-chain (Pizza never ran confirmUpgrade) — v0.5.6 supersedes it
- V5.5 commit `da30f66` preserved in history; v0.5.6 builds cleanly on top

---

## MineController v0.5.1 — 2026-02-26
**Contract:** `0x4F59C57eB19BabBdEe5D5ED645FEB3EC2e37C7D2` (verified Basescan)
**Previous:** `0xd90C5266077254E607B0908be092aB9aCe70323a` (V5.0 — deprecated)
**Source:** `src/CustosMineControllerV5.sol`
**Status:** LIVE — active oracle, frontend, and monitor all updated

### Changes vs v0.5.0
- **Mid-epoch staking:** `stake()` now auto-writes `tierSnapshot[epochId][msg.sender]` immediately if called while epoch is open and `snapshotComplete = true`. New stakers earn credits from the very next settled round — no waiting for next epoch.
- Unstake / withdrawal flow unchanged.

### Tests
- 35/35 passing (`test/CustosMineControllerV5.t.sol`)
- 2 new tests covering mid-epoch stake behaviour

### Deployment
- Deployed by market-maker wallet `0x0528B8FE...`
- Verified: https://basescan.org/address/0x4f59c57eb19babbdee5d5ed645feb3ec2e37c7d2
