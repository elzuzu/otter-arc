# ⚡ ArcPay — Agentic Micro-Payment Gateway on Arc Mainnet

> **Native USDC Micro-Payments & Autonomous Escrow Gateway for AI Agents on Arc Mainnet (Chain ID 5042).**  
> *Built for the [Arc Microgrants Program](https://community.arc.io/public/events/arc-microgrants-f8tijfjhyq) (Circle).*

---

## 🌐 Overview & Arc-Native Value

**Arc** is Circle's flagship Layer 1 blockchain designed as an **Economic Operating System for the Internet**, featuring **native USDC gas**. 

**ArcPay** is a high-performance, developer-friendly micro-payment protocol and interactive gateway designed specifically to exploit Arc's unique blockchain architecture:

1. **Native USDC Gas & Value Transfer**:
   - On standard EVM chains, paying with stablecoins requires an `ERC20.approve()` transaction followed by a `transferFrom()`, doubling gas fees and friction.
   - On Arc Mainnet, USDC **is** the native gas token. ArcPay handles direct value transfers using native `msg.value` (USDC), saving over 50% gas and enabling instant zero-approval settlement.
2. **Built-in 6-Decimals Precision**:
   - Arc native gas uses 6 decimals ($1\text{ USDC} = 1,000,000\text{ units}$).
   - ArcPay is calibrated for micro-transactions ($0.001 - $0.05 USDC) ideal for pay-per-call AI agents, automated data scraping, and high-frequency oracles.
3. **Autonomous Multi-Agent Escrow**:
   - Enables trustless micro-escrows for asynchronous AI agent pipelines with automated deadline refunds.

---

## 🏗️ Architecture

```
                      +-----------------------------+
                      |   Autonomous AI Agent       |
                      |   (or Web3 User / Dapp)     |
                      +--------------+--------------+
                                     |
               (1) Pay-per-Call /    |   (2) Lock Escrow /
               Native USDC transfer  |   Query Result
                                     v
                 +-----------------------------------+
                 |        ArcAgentGateway.sol        |
                 |     (Arc Mainnet - Chain 5042)    |
                 +-----------------+-----------------+
                                   |
           +-----------------------+-----------------------+
           |                                               |
           v                                               v
+-----------------------+                       +-----------------------+
|  Service Registry     |                       |  Autonomous Escrows   |
|  - Instant routing    |                       |  - Time-locked tasks  |
|  - Pull withdrawals   |                       |  - Non-custodial      |
|  - Excess auto-refund |                       |  - Auto-refund logic  |
+-----------------------+                       +-----------------------+
```

---

## ⚡ Quick Start

### 1. Verification of Network & Balance
Check your connection to Arc Mainnet and check your wallet balance:
```bash
npm run check-balance
```

### 2. Run Smart Contract Tests (Forge)
All 4 core tests run in under 5ms:
```bash
npm test
```
Tests pass:
- `test_RegisterAndPayService()`
- `test_PayServiceWithExcessRefund()`
- `test_EscrowWorkflow()`
- `test_EscrowRefundAfterDeadline()`

### 3. Deploy to Arc Mainnet
Copy `.env.example` to `.env` and paste your private key:
```bash
cp .env.example .env
# Edit .env and set PRIVATE_KEY=...
```
Once your address holds a small amount of USDC on Arc Mainnet, run:
```bash
npm run deploy
```
The script will:
- Check your native USDC balance.
- Deploy `ArcAgentGateway.sol` to Arc Mainnet.
- Automatically save the deployed address to `frontend/src/contracts/deployedAddress.json`.
- Output verified ArcScan links.

### 4. Launch the Interactive Frontend
```bash
npm run dev
```
Open `http://localhost:5173` to test:
- Live Arc Block Height and RPC latency tracker.
- Pay-per-call agentic service execution demo.
- Multi-agent micro-escrow creation.
- 6-decimal USDC gas calculator vs Ethereum.

---

## 🚀 1-Click Frontend Deployment (Vercel / Cloudflare)

To deploy the frontend to Vercel in 30 seconds:
```bash
cd frontend
npx vercel --prod
```

---

## 📜 Arc Mainnet Parameters
- **Network Name**: Arc Mainnet
- **Chain ID**: `5042`
- **RPC URL**: `https://rpc.mainnet.arc.io`
- **Native Currency**: USDC (6 decimals)
- **Explorer**: [https://arcscan.app](https://arcscan.app)
- **Documentation**: [https://docs.arc.network](https://docs.arc.network)

---

## 📄 License
MIT © 2026 OtterArc Team
