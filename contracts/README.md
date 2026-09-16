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
forge test          # 36 tests; 4 of them fork Arc Mainnet
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

Optimistic, with no on-chain arbiter, and bounded rather than fair — see the root README for why
an unbounded reject loop cannot be made fair between two mutually distrusting parties.

1. `createEscrow(worker, taskHash, deadline, maxRejections, redoWindow)` locks native USDC.
   `deadline` is at most `MAX_TERM` (365 days) from now; `maxRejections` is at most
   `MAX_REJECTIONS` (3); `redoWindow` is between `REVIEW_WINDOW` (1 hour) and `MAX_REDO_WINDOW`
   (30 days). All four are readable on chain before the worker starts.
2. `submitResult` — worker only, strictly before the deadline, non-empty result. Pays nothing.
3. `releaseEscrow` — payer only, at any time before the escrow closes.
4. `rejectResult` — payer only, while budget remains and the review period is open. Returns the
   escrow to `PENDING` **and pushes the deadline to at least `now + redoWindow`** (the window
   agreed at creation, not a fixed floor — a late rejection cannot collapse a long job's redo time).
5. `claimSubmittedEscrow` — worker only, once `reviewDeadline` passes. Silence pays the worker.
6. `splitEscrow` — payer only, once `rejectionsLeft == 0` and the escrow is still `SUBMITTED`.
   Splits the amount 50/50 and closes the dispute. This is what stops a worker from being able to
   win the whole escrow with a bad-faith submission by simply outlasting the budget.
7. `refundEscrow` — payer only: a `PENDING` escrow past its deadline, or a `SUBMITTED` one the
   worker left uncollected for `CLAIM_WINDOW`, so nothing is ever stranded.

`reviewDeadline(id)` — when `rejectResult` / `splitEscrow` close and `claimSubmittedEscrow` opens
— is `max(deadline, submittedAt + REVIEW_WINDOW)`, the fixed one-hour constant, **not**
`redoWindow`. `redoWindow` plays a different role: it is how far `rejectResult` pushes `deadline`
forward on a rejection, which is what stops a late rejection from collapsing a long job's answer
time. The two windows do not otherwise interact.
