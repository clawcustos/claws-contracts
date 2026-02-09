# Claws Contracts

Solidity smart contracts for the Claws agent speculation protocol on Base.

## Build & Test

```bash
forge build
forge test
```

## Architecture

- **Claws.sol** — Core contract. Per-agent bonding curve markets, EIP-712 verification, fee distribution.
- **Deploy.s.sol** — Deployment script.

## Key Parameters

| Parameter | Value |
|-----------|-------|
| Chain | Base (8453) |
| Bonding Curve | `price = supply² / 48000 ETH` |
| Protocol Fee | 5% |
| Agent Fee | 5% |
| Verification | EIP-712 signed proofs |
| Ownership | Two-step transfer |
