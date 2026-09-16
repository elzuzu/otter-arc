# ArcPay — Agentic Micro-Payment & Escrow Gateway on Arc Mainnet

> Native-USDC pay-per-call and autonomous escrow rails for AI agents, targeting **Arc Mainnet
> (Chain ID 5042)** — with correct handling of Arc's two USDC representations.
>
> **Deployment status:** the contract address, once deployed, is written to
> [`frontend/src/contracts/deployedAddress.json`](frontend/src/contracts/deployedAddress.json) and
> linked here. While that file is empty, nothing is deployed yet.
> Built for the [Arc Microgrants program](https://community.arc.io/public/events/arc-microgrants-f8tijfjhyq).

---

## The Arc detail this project is built around

Arc uses USDC as its gas token. That single sentence hides an integration trap, and it is the
reason this project exists in its current form.

| | Native gas asset | USDC ERC-20 predeploy |
|---|---|---|
| Read via | `msg.value`, `address.balance`, `eth_getBalance` | `balanceOf` on `0x3600000000000000000000000000000000000000` |
| Decimals | **18** | **6** |
| Relationship | — | `floor(native / 1e12) == balanceOf` |

They are **two views of a single balance**, related by exactly `1e12`. Because USDC is a
6-decimal token on every other chain, assuming 6 decimals for Arc's *native* asset is the natural
mistake — and it overstates every balance by a factor of a trillion. A wallet holding 2 USDC
renders as 2,000,000,000,000 USDC; a balance check passes on an account holding a millionth of
what it needs.

ArcPay denominates everything in native units, converts explicitly through
[`ArcDecimals`](contracts/src/ArcDecimals.sol), and ships the claim as an **executable assertion**
rather than a sentence: `forge test` forks Arc Mainnet and checks the relationship against the
live chain.

### Verify it yourself in ten seconds

```bash
ADDR=0x5ACCC00D7e4dB975CCbfC2801bC9447f37198797   # an Arc validator

# native balance — 18 decimals
curl -s https://rpc.mainnet.arc.io -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$ADDR\",\"latest\"],\"id\":1}"

# the same balance through the ERC-20 predeploy — 6 decimals
curl -s https://rpc.mainnet.arc.io -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"0x3600000000000000000000000000000000000000\",\"data\":\"0x70a08231000000000000000000000000${ADDR:2}\"},\"latest\"],\"id\":1}"

# the predeploy's own decimals() — returns 0x06
curl -s https://rpc.mainnet.arc.io -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x3600000000000000000000000000000000000000","data":"0x313ce567"},"latest"],"id":1}'
```

Divide the first result by `1e12` and you get the second, exactly.

> One wrinkle worth knowing if you fork Arc locally: `balanceOf` and `decimals` execute fine, but
> `totalSupply()` routes through an Arc precompile at `0x1800000000000000000000000000000000000000`
> that holds no bytecode, so a local EVM rejects it with `OpcodeNotFound`. The fork test reads that
> one value over RPC instead.

---

## What ArcPay does

**1. Pay-per-call agent paywall.** Providers register an agent service in an on-chain registry with
a per-invocation fee. Callers pay with a single `payForService(uint256,bytes32,uint256)`
transaction — `msg.value` carries the fee, no ERC-20 `approve` + `transferFrom` round-trip, because
on Arc the stablecoin *is* the gas token. The third argument is the highest fee the caller accepts,
so a provider cannot raise the price in front of the transaction and keep the whole `msg.value`.
Overpayment is credited back to the caller's claimable balance.

**2. Autonomous micro-escrow.** `createEscrow` locks native USDC against a task hash and a
deadline. The worker publishes a non-empty result with `submitResult`, strictly before the
deadline; this pays nothing. The payer then has until `max(deadline, submittedAt + 1 hour)` to
either `releaseEscrow` or `rejectResult` — a rejection returns the escrow to pending, so the worker
can try again while the deadline allows. If the payer says nothing, the worker takes it with
`claimSubmittedEscrow`: silence pays the worker. If nothing acceptable is ever delivered, the payer
calls `refundEscrow` after the deadline, and a submission the worker never collects becomes
refundable after a further 30 days, so no escrow can be stranded.

The rule is therefore explicit: **the payer decides before the deadline, and silence pays the
worker.** A worker cannot take the money for work the payer refuses, and a payer cannot take
delivery and then stay quiet. What this does *not* do is adjudicate a genuine disagreement — that
needs a third party, and is deliberately out of scope.

**3. Pull-payment settlement.** Every credit — fees, released escrows, refunds, and overpayment on
a service call — lands in `claimableBalances` and is withdrawn by the earner. The contract never
pushes value to an address that might revert, so a contract counterparty with no `receive()` can
still be paid. `withdraw()` is the single exit, and the reentrancy guard covers every value-moving
path. There is deliberately no `receive()`: stray value would be unrecoverable, so it reverts.

---

## Architecture

```
          Autonomous agent / dapp / user
                        │
        pay-per-call    │    lock escrow
        (msg.value)     │    (msg.value)
                        ▼
        ┌───────────────────────────────┐
        │      ArcAgentGateway.sol      │
        │   Arc Mainnet — chain 5042    │
        └───────────────┬───────────────┘
                        │ uses
                        ▼
        ┌───────────────────────────────┐
        │       ArcDecimals.sol         │
        │  native 18 dec ⇄ ERC-20 6 dec │
        │        factor 1e12            │
        └───────────────────────────────┘
                        │ reads
                        ▼
        USDC ERC-20 predeploy 0x3600…0000
```

---

## Quick start

```bash
npm install
npm test            # 26 tests, 4 of them forked against live Arc Mainnet
npm run check-balance
```

`npm test` requires network access on purpose: the fork tests assert against the live chain, and a
claim about a live chain that can silently skip itself is not a proof.

### Deploy

```bash
cp .env.example .env     # set PRIVATE_KEY
npm run deploy           # builds, syncs the artifact, estimates gas, then deploys
npm run seed             # registers demo services and makes one real paid call
```

`npm run deploy` prices the deployment before spending anything and refuses to broadcast unless
the balance covers three times the estimate. `eth_estimateGas` against Arc Mainnet for the current
bytecode returns **2,002,641 gas**, which at 20 gwei is **≈ 0.040 USDC**. That is an estimate from
the live chain, not a figure from an actual deployment — nothing has been deployed yet, and gas
price on Arc has moved between 20 and 39 gwei since mainnet opened, so treat it as an order of
magnitude.

### Frontend

```bash
npm run dev              # http://localhost:5173
npm run build
```

The dashboard is configured to publish to GitHub Pages at `elzuzu.github.io/otter-arc/`, from the
prebuilt `gh-pages` branch, with `.github/workflows/deploy-pages.yml` available as a build-from-
source alternative. Vite's `base` defaults to `/otter-arc/` for that sub-path; set `BASE_PATH=/`
to build for a root-hosted deploy.

Note on CI: user-defined GitHub Actions workflows are currently blocked on this account by a
billing lock, so `test.yml` shows no green badge. The Pages build from a branch is a built-in
GitHub job and is unaffected, which is why the site is live regardless. Everything the CI would
run — `forge test`, `forge fmt --check`, the frontend build and lint, and `check-links` — passes
locally and can be reproduced with the commands above.

The dashboard reads the service registry from chain (not a hardcoded list), sends real contract
calls, and carries a **Decimals Proof** panel that reads any address's balance both ways and shows
the `1e12` relationship live.

### Checks

```bash
npm run check-links      # the URLs a reader follows must answer (see the file for scope)
npm run verify           # tests + links
```

---

## Arc Mainnet parameters

| | |
|---|---|
| Network | Arc Mainnet |
| Chain ID | `5042` (`0x13b2`) |
| RPC | `https://rpc.mainnet.arc.io` (fallbacks: `rpc.drpc.mainnet.arc.io`, `rpc.quicknode.mainnet.arc.io`) |
| Explorer | <https://explorer.arc.io> |
| Native currency | USDC, **18 decimals** |
| USDC ERC-20 | `0x3600000000000000000000000000000000000000`, **6 decimals** |
| Docs | <https://docs.arc.network> |

---

## Repository layout

| Path | What it is |
|---|---|
| `contracts/src/ArcAgentGateway.sol` | Registry, pay-per-call, escrow, pull withdrawals |
| `contracts/src/ArcDecimals.sol` | The 18 ⇄ 6 conversion library and predeploy interface |
| `contracts/test/ArcAgentGateway.t.sol` | Unit and fuzz tests |
| `contracts/test/ArcMainnetFork.t.sol` | Assertions against live Arc Mainnet |
| `scripts/arc-chain.mjs` | Single source of truth for chain parameters |
| `scripts/deploy.mjs` | Gas-priced deployment with a balance guard |
| `scripts/seed-services.mjs` | Brings the deployed registry to life on chain |
| `scripts/check-links.mjs` | Fails the build on a dead URL |
| `frontend/` | React + Tailwind dashboard |

---

## License

MIT © 2026 OtterArc
