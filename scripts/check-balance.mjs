import { createPublicClient, http, formatUnits } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import dotenv from 'dotenv';
dotenv.config();

// Arc Mainnet Definition
export const arcMainnet = {
  id: 5042,
  name: 'Arc Mainnet',
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 6 },
  rpcUrls: {
    default: { http: [process.env.ARC_RPC_URL || 'https://rpc.mainnet.arc.io'] },
  },
  blockExplorers: {
    default: { name: 'ArcScan', url: 'https://arcscan.app' },
  },
};

const client = createPublicClient({
  chain: arcMainnet,
  transport: http(),
});

async function main() {
  console.log('\n======================================================');
  console.log('       ARC MAINNET - WALLET & NETWORK CHECK           ');
  console.log('======================================================');

  try {
    const blockNumber = await client.getBlockNumber();
    const gasPrice = await client.getGasPrice();
    console.log(`[+] Arc Mainnet RPC: ${arcMainnet.rpcUrls.default.http[0]}`);
    console.log(`[+] Current Block Number: #${blockNumber.toString()}`);
    console.log(`[+] Gas Price: ${gasPrice.toString()} micro-units (${formatUnits(gasPrice, 6)} USDC/unit)`);
  } catch (err) {
    console.warn(`[!] Note: Arc Mainnet RPC ping returned: ${err.message}`);
  }

  let address = process.env.WALLET_ADDRESS;
  if (!address && process.env.PRIVATE_KEY) {
    try {
      const rawKey = process.env.PRIVATE_KEY.trim();
      const formattedKey = rawKey.startsWith('0x') ? rawKey : `0x${rawKey}`;
      const account = privateKeyToAccount(formattedKey);
      address = account.address;
    } catch (e) {
      console.error('[x] Invalid PRIVATE_KEY in .env');
    }
  }

  if (!address) {
    console.log('\n[!] No WALLET_ADDRESS or PRIVATE_KEY defined in .env');
    console.log('    Add your PRIVATE_KEY or WALLET_ADDRESS in .env to check your balance.');
    console.log('======================================================\n');
    return;
  }

  console.log(`\n[>] Target Wallet Address: ${address}`);
  try {
    const balance = await client.getBalance({ address });
    // Arc native gas is USDC with 6 decimals
    const balanceUsdc = formatUnits(balance, 6);
    console.log(`[✓] Native Gas Balance: ${balanceUsdc} USDC`);

    if (balance === 0n) {
      console.log('\n[!] Balance is 0 USDC. To deploy on Arc Mainnet, bridge a small amount');
      console.log('    of USDC via Circle CCTP or transfer USDC on Arc to your address:');
      console.log(`    👉 ${address}`);
    } else {
      console.log('\n[🎉] Wallet is funded and ready for deployment!');
    }
  } catch (err) {
    console.error(`[x] Error querying balance: ${err.message}`);
  }
  console.log('======================================================\n');
}

main().catch(console.error);
