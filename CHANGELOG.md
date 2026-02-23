# CustosNetwork Contract Changelog

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
