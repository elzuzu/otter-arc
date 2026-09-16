# ArcPay contracts

Solidity for the ArcPay gateway on Arc Mainnet (chain 5042). Built with Foundry.

| File | Purpose |
|---|---|
| `src/ArcAgentGateway.sol` | Agent service registry, pay-per-call settlement, escrow, pull withdrawals |
| `src/ArcDecimals.sol` | Conversion between Arc's native 18-decimal USDC and the 6-decimal ERC-20 predeploy |
| `test/ArcAgentGateway.t.sol` | Unit, fuzz and regression tests |
| `test/ArcMainnetFork.t.sol` | Assertions against **live** Arc Mainnet |

## Running

```bash
forge build
forge test          # 21 tests; 4 of them fork Arc Mainnet
forge fmt --check
```

`forge test` needs network access. The fork endpoint is declared as `arc` in `foundry.toml`, and
the fork tests have no self-skip path on purpose: a claim about a live chain that can quietly skip
itself is not a proof, so an outage fails the suite rather than reporting a green run.

## The decimal model

Arc exposes one USDC balance through two representations:

- native gas asset (`msg.value`, `address.balance`) — **18 decimals**
- USDC ERC-20 predeploy `0x3600000000000000000000000000000000000000` — **6 decimals**

related by exactly `1e12`, so `floor(native / 1e12) == balanceOf(account)`. Every amount in these
contracts is denominated in **native units**; `ArcDecimals` is the only place the conversion
happens. See the root README for the full explanation and reproduction commands.

## Escrow semantics

Optimistic, with no on-chain arbiter:

1. `createEscrow` locks native USDC against a task hash and a deadline.
2. `submitResult` — worker only, before the deadline. Publishes the result and opens a
   `REVIEW_WINDOW` (1 hour). It pays nothing.
3. `releaseEscrow` — payer only, at any time before a refund.
4. `claimSubmittedEscrow` — worker only, once the review window closes on a submitted result, so a
   silent payer cannot strand delivered work.
5. `refundEscrow` — payer only, after the deadline and only while still `PENDING`, so a payer
   cannot refund out from under work that was delivered.

Arbitrating a *disputed* result is explicitly out of scope and would need a third party.
