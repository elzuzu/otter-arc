# ArcPay — Agentic Micro-Payment & Escrow Gateway on Arc Mainnet

> Native-USDC pay-per-call and autonomous escrow rails for AI agents, targeting **Arc Mainnet
> (Chain ID 5042)** — with correct handling of Arc's two USDC representations.
>
> **Live on Arc Mainnet** at
> [`0x4704b3e740376434b05587b58e30a901f79434e4`](https://explorer.arc.io/address/0x4704b3e740376434b05587b58e30a901f79434e4),
> deployed in block #21274816. The address is recorded in
> [`frontend/src/contracts/deployedAddress.json`](frontend/src/contracts/deployedAddress.json) and
> read from there by the dashboard. `npm run verify-deployment` re-derives every claim below from
> the chain using nothing but that address.
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

> **A registry stores strings, and cannot vouch for them — including ours.** `registerService`
> takes an `endpoint` and writes it verbatim; `updateService` can change the fee and the active
> flag but *not* the endpoint, which is immutable once registered. The three demo services seeded
> on the live deployment were registered pointing at `agents.arcpay.dev`, a host this project does
> not own and which answers 404. That cannot be corrected on chain, so it is documented here
> instead: read the endpoint of any service in this or any other registry as a claim by its
> provider, never as something the contract checked. `scripts/seed-services.mjs` now seeds URLs
> that resolve, and the dashboard labels the field for what it is.

**2. Autonomous micro-escrow.** `createEscrow` locks native USDC against a task hash, a
deadline (at most `MAX_TERM`, one year), a **number of rejections the payer reserves** (at most
`MAX_REJECTIONS`), and a **redo window** the worker gets after each rejection (between
`REVIEW_WINDOW` and `MAX_REDO_WINDOW`). All four are fixed at creation and readable on chain, so
the worker prices the job before starting. The worker publishes a non-empty result with
`submitResult` strictly before the deadline; this pays nothing. The payer may then `releaseEscrow`,
or `rejectResult` while budget remains — **which pushes the deadline out by the agreed redo
window, never less**, so a late rejection can never collapse a long job into an hour. If the payer
says nothing, the worker takes it with `claimSubmittedEscrow`.

Three cycles of adversarial review converged on one fact: **an unbounded two-party reject loop
always hands one side a dominant strategy.** A worker-favoring version let junk win the whole
escrow by outlasting a fixed rejection budget — submit one byte of nothing, absorb every
rejection, and the delivery after the budget runs out is unconditionally claimable. Fixing that
with an *unbounded* right of refusal just moves the problem to the payer, who then wins by
rejecting forever and outspending the worker in gas.

The design does not pretend to solve this by being clever; it bounds it. Once the rejection budget
is spent, the payer's move is no longer silence or acceptance — it is `splitEscrow`, which closes
the dispute 50/50. A worker gambling on junk is capped at half the escrow instead of the whole
thing; a payer who genuinely received nothing usable still recovers half instead of paying for it
in full. **What this does not do is adjudicate who was right** — that needs a third party, and is
deliberately out of scope. The contract bounds the damage either side can extract by being
unreasonable; it does not claim to judge quality.

If nothing acceptable is ever delivered, the payer refunds after the deadline; a submission the
worker never collects becomes refundable after a further 30 days (`CLAIM_WINDOW`), so no escrow is
ever stranded — including by a `deadline` set absurdly far out, which `MAX_TERM` now forbids.

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
npm test            # 36 tests, 4 of them forked against live Arc Mainnet
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

Rehearse it against a local fork before spending anything — `ARC_RPC_URL` and the frontend's
`VITE_ARC_RPC_URL` both *replace* the endpoint list rather than prepending to it, so a run aimed at
a fork cannot fall through to mainnet:

```bash
anvil --fork-url https://rpc.mainnet.arc.io --port 8555 &
ARC_RPC_URL=http://127.0.0.1:8555 PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  npm run deploy && ARC_RPC_URL=http://127.0.0.1:8555 PRIVATE_KEY=0xac09…ff80 npm run seed
VITE_ARC_RPC_URL=http://127.0.0.1:8555 npm run dev
```

That is the same code path as a real deployment, against a chain that reports the same chain ID
and the same predeploys.

`npm run deploy` prices the deployment before spending anything and refuses to broadcast unless
the balance covers three times the estimate. `eth_estimateGas` against Arc Mainnet for the current
bytecode returns **2,300,390 gas** — that part is a property of the bytecode and reproducible, so
run it yourself rather than trusting the number here.

The *price* is not. Arc mainnet opened on 16 September 2026 and `eth_gasPrice` moved between
**20 and 225 gwei** within a few hours of this being written, which is the difference between a
deployment costing 0.042 USDC and 0.47 USDC. Read the current price rather than trusting any
figure quoted here:

```bash
curl -s https://rpc.mainnet.arc.io -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_gasPrice","params":[],"id":1}'
```

The deployment has since happened, so the figures above can be checked against a real transaction
rather than an estimate. It cost **2,281,119 gas at 20 gwei = 0.04562238 USDC** in block #21274816,
for 10,204 bytes of runtime code — slightly under the 2,300,390 estimate above, as an estimate
should be. An earlier revision of this README quoted 2,110,584 for a smaller version of the
contract; the escrow gained `splitEscrow` and the bounded-rejection machinery after that, and the
figure was not revisited. Hence the standing advice: run `eth_estimateGas` yourself.

### Verifying the source on the explorer

The deployed contract is **not source-verified on `explorer.arc.io` yet**, so the Contract tab
shows creation bytecode rather than Solidity. Stating that is cheaper than letting a reader
discover it.

The explorer is Blockscout, and both of its doors are shut to automation. The API sits behind a
Cloudflare managed challenge that answers non-browser clients with the challenge page instead of
JSON, so `forge verify-contract --verifier blockscout` fails to deserialise a response it never
received. The web form at `/address/<addr>/contract-verification` fills in fine, but its submit is
reCAPTCHA-gated and does nothing without a token.

Neither is a bug to work around — they are the explorer's bot protections doing their job. So this
is a one-minute manual step in a real browser: open the contract's **Contract** tab, click
**Verify & publish**, choose **Solidity (Standard JSON Input)**, set the compiler and licence to
the values below, and upload
[`contracts/standard-json-input.json`](contracts/standard-json-input.json), which is committed here
for exactly that purpose.

The settings it must be matched with, all readable in that file:

| | |
|---|---|
| Compiler | `v0.8.33+commit.64118f21` |
| Optimizer | enabled, 200 runs |
| EVM version | `prague` |
| Constructor args | none |

Regenerate the file after any change to the contract:

```bash
cd contracts && forge verify-contract 0x4704b3e740376434b05587b58e30a901f79434e4 \
  src/ArcAgentGateway.sol:ArcAgentGateway --show-standard-json-input > standard-json-input.json
```

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
billing lock — each push queued them, failed in about four seconds with "The job was not started
because your account is locked due to a billing issue", and mailed a failure notice. Their
automatic triggers are therefore switched off and they run on `workflow_dispatch` only; the
definitions are kept because they document exactly what CI runs, and the `push`/`pull_request`
keys go back in once billing is sorted.

None of that affects the live site: GitHub Pages serves the prebuilt `gh-pages` branch through the
built-in `pages build and deployment` job, which is not one of this repository's workflows and runs
fine. Everything the CI would run — `forge test`, `forge fmt --check`, the frontend build and lint,
and `check-links` — passes locally and is reproducible with the commands above.

The dashboard reads the service registry from chain (not a hardcoded list), sends real contract
calls, and carries a **Decimals Proof** panel that reads any address's balance both ways and shows
the `1e12` relationship live.

### Checks

```bash
npm run check-links        # the URLs a reader follows must answer (see the file for scope)
npm run verify             # tests + links
npm run verify-deployment  # read the deployment back off the chain and check it
```

`verify-deployment` needs nothing but the contract address. It reads the denomination constants
out of the deployed bytecode, compares the contract's own `nativeBalanceAsErc20` against
`eth_getBalance` and the predeploy's `balanceOf` for a real account, confirms the registry has
been used rather than merely deployed, and checks that the escrow's safety entry points are
actually present. It exits non-zero on any failure — verified by pointing it at an address with no
code, and at a deployed-but-unseeded contract.

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
| `scripts/verify-deployment.mjs` | Reads a deployment back off-chain and checks it |
| `scripts/publish-site.sh` | Builds the dashboard and publishes it to `gh-pages` |
| `frontend/` | React + Tailwind dashboard |

---

## License

MIT © 2026 OtterArc
