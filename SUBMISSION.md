# Arc Microgrants submission — ArcPay

Portal: **DoraHacks** — <https://dorahacks.io/hackathon/arc-microgrants>
(the Arc House event page at
<https://community.arc.io/public/events/arc-microgrants-f8tijfjhyq> links here; its own
"Register" button is for the event, not the grant submission).

Deadline: **14 October 2026, 23:59 ET** (DoraHacks shows the window closing 2026/10/15 03:59).

Two rules below are stated on the Arc House event page rather than on DoraHacks, so they are
quoted verbatim from <https://community.arc.io/public/events/arc-microgrants-f8tijfjhyq>:
"Reviews run on a rolling basis and every decision is issued by October 21." and
"One submission per project. Teams can submit more than one distinct project."
**There is therefore no second attempt on this project.**

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

## Cover image

Upload [`docs/buidl-cover.png`](docs/buidl-cover.png) — 1200x630, the ratio DoraHacks renders a
BUIDL card at. The two figures on it are a real Arc validator balance read from the live chain,
shown through both representations; [`docs/buidl-cover.html`](docs/buidl-cover.html) regenerates it
if the numbers should be refreshed.

## Live deployment on Arc mainnet

```
App:      https://elzuzu.github.io/otter-arc/
Contract: 0x4704b3e740376434b05587b58e30a901f79434e4
Explorer: https://explorer.arc.io/address/0x4704b3e740376434b05587b58e30a901f79434e4
```

## Public repository

```
https://github.com/elzuzu/otter-arc
```

## Public builder profile

```
https://github.com/elzuzu
```

## Payout wallet (USDC on Arc)

```
0xd3fb4e6479749100D876584e7F5c5cC1EEAE51A5
```

---

## Description

ArcPay is the settlement layer for agents that have to pay each other in small amounts, built for
Arc mainnet.

On a normal EVM chain, paying a stablecoin means `approve` followed by `transferFrom`: two
transactions, two gas payments, and an allowance left sitting on chain. On Arc, USDC **is** the gas
token, so a payment is just `msg.value`. ArcPay is built around that: an on-chain registry where a
provider lists an agent service and its per-call fee, a single `payForService(uint256,bytes32,uint256)`
call that settles it with no approval round-trip, carries the caller's own maximum-fee bound so a
provider cannot front-run the price, and credits any overpayment back. Alongside it, an escrow whose design was tested to destruction across three adversarial
review rounds and rebuilt each time. A worker publishes a non-empty result strictly before the
deadline, which pays nothing. The payer may release, or reject while a fixed, on-chain-visible
budget remains — each rejection pushing the deadline out by the redo window agreed at creation, so
"try again" is real rather than a formality. If the payer says nothing, the worker claims it.

The reviews proved something worth stating plainly: an unbounded two-party reject loop always
hands one side a dominant strategy. A worker could win the whole escrow with one byte of junk by
outlasting a fixed rejection budget; making the right of refusal unbounded to stop that just
handed the payer the same unilateral win instead. The fix does not pretend to solve this by being
clever — it bounds it. Once the budget is spent, the payer's move is `splitEscrow`: 50/50, closing
the dispute. Junk nets a worker at most half the escrow, never all of it. Adjudicating who was
actually right needs a third party and is deliberately out of scope; the contract bounds what
either side can extract by being unreasonable, and does not claim to judge quality.
Every credit — fees, released escrows, refunds, overpayment —
accrues to a claimable balance and is pulled by the earner, so the contract never pushes value to
an address that might revert.

The project also solves a problem that will bite most day-one Arc integrations, and this is the
part we think is most useful to the ecosystem.

**Arc exposes the same USDC balance twice, with different decimals.** The native gas asset — what
`msg.value`, `address.balance` and `eth_getBalance` speak — carries **18 decimals**. The USDC
ERC-20 predeploy at `0x3600000000000000000000000000000000000000` reports the same balance with
**6**. They are related by exactly `1e12`: `floor(native / 1e12) == balanceOf(account)`.

Because USDC is a 6-decimal token everywhere else, assuming 6 decimals for Arc's *native* asset is
the natural mistake — and it overstates every balance by a factor of a trillion. A wallet holding
2 USDC renders as 2,000,000,000,000 USDC. A "do I have enough to deploy" check passes on an account
holding a millionth of what it needs. It is a silent failure: nothing reverts, the numbers are
simply wrong, and both the AI-written guides and the chain registries disagree with each other on
this point.

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
- **A bounded escrow, not a naive one.** `submitResult` / `rejectResult` / `releaseEscrow` /
  `claimSubmittedEscrow` / `refundEscrow` / `splitEscrow` form a state machine sized to close two
  successive full-escrow exploits found by adversarial review — one favoring the worker, the
  inverse favoring the payer — without pretending an on-chain contract can judge work quality.
- **Cheap enough for per-call pricing.** `eth_estimateGas` on live Arc returns **2,110,584 gas**
  for this bytecode. The price is another matter: mainnet is days old and `eth_gasPrice` moved
  between **20 and 225 gwei** while this was being written, i.e. 0.042 to 0.47 USDC for the same
  deployment. A service call is a fraction of that either way. We quote the gas, which is
  reproducible, and tell the reader to read the price themselves.
- **Arc's actual predeploy topology.** `0x3600…0000` is a proxy; `totalSupply()` routes to an Arc
  precompile at `0x1800…0000` that holds no bytecode and that a local EVM rejects with
  `OpcodeNotFound`. Our fork test reads that one value over RPC instead. Documented in the README
  so the next builder does not lose an afternoon to it.

## How to verify the claims

```bash
npm test                  # 36 tests; 4 fork Arc mainnet and assert against the live chain
npm run check-balance     # prints any address's balance in both representations
npm run verify-deployment # reads the deployment back off-chain and checks every claim above
npm run check-links       # the URLs in the docs and source must resolve
```

`verify-deployment` is the short version of this whole submission: point it at the contract and it
re-derives the decimal relationship, the registry activity and the escrow's safety surface from
the chain, and exits non-zero if any of it is untrue.

Or with nothing but curl — see "Verify it yourself in ten seconds" in the README.

## What we would do next

On-chain arbitration for disputed escrow results, which the current optimistic model deliberately
leaves out; batch settlement so an agent can pay many providers in one transaction; a session-key
flow so an autonomous agent can spend under a bounded allowance without holding the owner key; and
publishing `ArcDecimals` as a standalone package, since every Arc integration needs it and getting
it wrong is silent.
