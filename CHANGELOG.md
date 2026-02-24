# CustosNetwork Contract Changelog

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
