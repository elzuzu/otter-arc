# Arc Microgrants submission — ArcPay

Portal: **DoraHacks** — <https://dorahacks.io/hackathon/arc-microgrants>
(the Arc House event page at
<https://community.arc.io/public/events/arc-microgrants-f8tijfjhyq> links here; its own
"Register" button is for the event, not the grant submission).

Deadline: **14 October 2026, 23:59 ET.** Rolling review, all decisions by 21 October.
**One submission per project — there is no second attempt.**

Everything below is written to be pasted into the DoraHacks BUIDL form.

---

## Project name

```
ArcPay — Agentic Micro-Payment & Escrow Gateway
```

## One-line pitch

```
Native-USDC pay-per-call and autonomous escrow rails for AI agents on Arc, with correct handling of Arc's 18-decimal native asset and 6-decimal USDC ERC-20.
```

## Tags

```
Arc, USDC, agentic payments, micro-payments, escrow, Solidity, infrastructure
```

## Tech stack

```
Solidity 0.8.33 · Foundry · viem · React 19 · Tailwind 4 · Vite
```

## Live deployment on Arc mainnet

```
App:      <FILL AFTER VERCEL DEPLOY>
Contract: <FILL AFTER npm run deploy>
Explorer: https://explorer.arc.io/address/<CONTRACT>
```

## Public repository

```
<FILL AFTER gh repo create>
```

## Public builder profile

```
https://github.com/elzuzu
```

## Payout wallet (USDC on Arc)

```
<FILL WITH THE DEDICATED ARC WALLET ADDRESS>
```

---

## Description

ArcPay is the settlement layer for agents that have to pay each other in small amounts, built for
Arc mainnet.

On a normal EVM chain, paying a stablecoin means `approve` followed by `transferFrom`: two
transactions, two gas payments, and an allowance left sitting on chain. On Arc, USDC **is** the gas
token, so a payment is just `msg.value`. ArcPay is built around that: an on-chain registry where a
provider lists an agent service and its per-call fee, a single `payForService(uint256,bytes32)`
call that settles it with no approval round-trip and refunds any overpayment, and a time-locked
`createEscrow` / `completeEscrow` / `refundEscrow` cycle for asynchronous multi-step agent work.
Earnings accrue to a claimable balance and are pulled by the earner, never pushed.

The project also solves a problem that will bite most day-one Arc integrations, and this is the
part we think is most useful to the ecosystem.

**Arc exposes the same USDC balance twice, with different decimals.** The native gas asset — what
`msg.value`, `address.balance` and `eth_getBalance` speak — carries **18 decimals**. The USDC
ERC-20 predeploy at `0x3600000000000000000000000000000000000000` reports the same balance with
**6**. They are related by exactly `1e12`: `floor(native / 1e12) == balanceOf(account)`.

Because USDC is a 6-decimal token everywhere else, assuming 6 decimals for Arc's *native* asset is
the natural mistake — and it overstates every balance by a factor of a trillion. A wallet holding
2 USDC renders as 2,000,000,000,000 USDC. A "do I have enough to deploy" check passes on an account
holding a millionth of what it needs. We know because our own first version shipped that bug
end to end, in the contract, the scripts and the UI.

ArcPay denominates every amount in native units, converts explicitly through a small `ArcDecimals`
library, and — rather than asserting the relationship in prose — ships it as an executable test:
`forge test` forks Arc mainnet and checks `floor(native / 1e12) == balanceOf` against the live
chain on every run. The dashboard carries the same proof as a live panel: paste any address, read
its balance both ways, see the `1e12` factor and the truncated remainder.

## What it uses Arc for

- **USDC as the gas token.** Settlement is a bare `msg.value` transfer. No ERC-20 approval, no
  allowance surface, one transaction instead of two. This is only possible because Arc makes the
  stablecoin the native asset.
- **The dual 18/6 representation, handled correctly and demonstrated.** `ArcDecimals` converts
  between the native 18-decimal unit and the 6-decimal ERC-20 unit, documents that the downward
  conversion truncates by less than one millionth of a USDC, and exposes
  `nativeBalanceAsErc20(address)` so the equality can be checked on chain. A fork test asserts it
  against live Arc; a UI panel shows it live.
- **Sub-cent economics.** Deployment measured at ~1.6M gas ≈ **0.032 USDC**, and a service call
  costs a fraction of a cent, which is what makes per-call agent pricing viable at all.
- **Arc's actual predeploy topology.** `0x3600…0000` is a proxy; `totalSupply()` routes to an Arc
  precompile at `0x1800…0000` that holds no bytecode and that a local EVM rejects with
  `OpcodeNotFound`. Our fork test reads that one value over RPC instead. Documented in the README
  so the next builder does not lose an afternoon to it.

## How to verify the claims

```bash
npm test          # 13 tests; 4 fork Arc mainnet and assert against the live chain
npm run check-balance   # prints any address's balance in both representations
npm run check-links     # every URL in the docs and source must resolve
```

Or with nothing but curl — see "Verify it yourself in ten seconds" in the README.

## What we would do next

Batch settlement so an agent can pay many providers in one transaction; a session-key flow so an
autonomous agent can spend under a bounded allowance without holding the owner key; and publishing
`ArcDecimals` as a standalone package, since every Arc integration needs it and getting it wrong is
silent.
