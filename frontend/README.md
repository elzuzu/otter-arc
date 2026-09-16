# ArcPay dashboard

React + Tailwind interface for the ArcPay gateway on Arc Mainnet (chain 5042). Built with Vite.

```bash
npm install
npm run dev      # http://localhost:5173
npm run build
npm run lint
```

The app talks to Arc over JSON-RPC with viem, and reads the deployed contract address from
`src/contracts/deployedAddress.json`, which `npm run deploy` writes at the repository root.

Three tabs:

- **Pay-per-Call Registry** — reads `getServiceCount()` / `services(i)` from chain and encodes a
  real `payForService(uint256,bytes32)` transaction. Not a hardcoded list.
- **Autonomous Micro-Escrow** — signs a real `createEscrow(address,bytes32,uint256)`.
- **Decimals Proof** — reads any address's balance both ways and shows that
  `floor(native / 1e12) == balanceOf`, with the curl commands to reproduce it without the page.

`src/arc.js` holds the chain parameters. Note `nativeCurrency.decimals: 18` — that is the value a
wallet uses to render a balance, and Arc's native gas asset really is 18 decimals even though USDC
is a 6-decimal token everywhere else.
