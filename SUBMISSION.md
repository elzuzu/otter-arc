# 📋 Formulaire de Soumission — Arc Microgrants (500 USDC)

Lien officiel de soumission : [https://community.arc.io/public/events/arc-microgrants-f8tijfjhyq](https://community.arc.io/public/events/arc-microgrants-f8tijfjhyq)

> 💡 **Conseil** : Remplissez le formulaire en anglais comme indiqué ci-dessous. Le programme traite les dossiers au fil de l'eau (*rolling basis*) jusqu'au 14 octobre 2026.

---

### 1. Project Name / Nom du projet
```
ArcPay — Agentic Micro-Payment & Escrow Gateway
```

### 2. Short Tagline / Slogan en 1 ligne
```
A native USDC micro-payment and autonomous escrow gateway built specifically for AI agents and tiny apps on Arc Mainnet.
```

### 3. Live Deployment Link / Lien de l'application en direct
```
https://[votre-app].vercel.app
(ou lien ArcScan de votre contrat une fois déployé : https://arcscan.app/address/0x...)
```
*Note : Vous pouvez déployer le frontend en 30 secondes avec `cd frontend && npx vercel --prod`.*

### 4. Public Repository Link / Lien du repo GitHub public
```
https://github.com/[votre-pseudo-github]/otter-arc
```

### 5. Description of the project / Description du projet
```
ArcPay is a high-performance, developer-ready micro-payment protocol and interactive gateway designed for the agentic economy on Arc Mainnet. 

As autonomous AI agents transact more frequently on-chain, traditional EVM stablecoin approval mechanisms (ERC-20 approve + transferFrom) create unnecessary latency and gas waste. ArcPay leverages Arc's unique architecture—where USDC is the native gas currency with 6 decimals precision—to offer:
1. Pay-per-Call Agent Paywall: Direct native value transfers (msg.value) to monetize AI agent tools, LLM inference queries, and real-time data feeds with zero ERC-20 approvals.
2. Autonomous Micro-Escrow: Time-locked, non-custodial escrows that allow agents and users to lock micro-payments for multi-step tasks, with automated deadline refunds.
3. Arc Native Precision: Native support for 6-decimal USDC accounting and sub-cent fee routing.

The project comes with a fully tested Solidity contract (ArcAgentGateway.sol), automated deployment scripts, and a modern dashboard featuring live Arc Mainnet RPC tracking and an interactive gas comparator.
```

### 6. What does your project use Arc for? / Comment votre projet utilise-t-il Arc ?
```
ArcPay is designed from the ground up for Arc Mainnet's unique economic properties:
- Native Gas Asset: Arc uses USDC natively for transaction gas. ArcPay handles direct value settlement in native USDC without wrapping or external token allowances.
- 6 Decimals Calibration: Unlike standard EVM chains (18 decimals), Arc utilizes 6 decimals for native currency. ArcPay's contract and UI are strictly designed around micro-USDC units (1 USDC = 1,000,000 units), making sub-cent transactions seamless.
- Agentic Economy: It provides the fundamental economic rail for autonomous agents on Arc to get paid and escrow funds for complex workflows.
```

### 7. Public Builder Profile / Profil de builder public
```
Votre profil GitHub (ex: https://github.com/votre-nom) ou votre compte X / Farcaster.
```

### 8. Payout Wallet Address / Adresse de réception (USDC sur Arc)
```
0x... (Votre adresse de wallet sur Arc Mainnet où vous recevrez les 500 USDC)
```
