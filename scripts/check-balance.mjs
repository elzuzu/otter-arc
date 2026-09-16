import { createPublicClient, fallback, http, formatUnits } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import dotenv from 'dotenv';
import {
  arcMainnet,
  ARC_RPC_URLS,
  USDC_ERC20,
  USDC_ABI,
  NATIVE_DECIMALS,
  ERC20_DECIMALS,
  SCALE,
  addressUrl,
} from './arc-chain.mjs';

dotenv.config();

const client = createPublicClient({
  chain: arcMainnet,
  transport: fallback(ARC_RPC_URLS.map((url) => http(url))),
});

async function main() {
  console.log('\n======================================================');
  console.log('       ARC MAINNET - WALLET & NETWORK CHECK           ');
  console.log('======================================================');

  try {
    const [blockNumber, gasPrice, chainId] = await Promise.all([
      client.getBlockNumber(),
      client.getGasPrice(),
      client.getChainId(),
    ]);
    console.log(`[+] RPC            : ${ARC_RPC_URLS[0]}`);
    console.log(`[+] Chain ID       : ${chainId}${chainId === 5042 ? ' (Arc Mainnet)' : ' (UNEXPECTED)'}`);
    console.log(`[+] Block number   : #${blockNumber}`);
    console.log(`[+] Gas price      : ${gasPrice} wei-equivalent (${formatUnits(gasPrice, 9)} gwei)`);
  } catch (err) {
    console.error(`[x] Arc Mainnet RPC unreachable: ${err.shortMessage || err.message}`);
    process.exitCode = 1;
    return;
  }

  let address = process.env.WALLET_ADDRESS;
  if (!address && process.env.PRIVATE_KEY) {
    try {
      const rawKey = process.env.PRIVATE_KEY.trim();
      const formattedKey = rawKey.startsWith('0x') ? rawKey : `0x${rawKey}`;
      address = privateKeyToAccount(formattedKey).address;
    } catch {
      console.error('[x] Invalid PRIVATE_KEY in .env');
    }
  }

  if (!address) {
    console.log('\n[!] No WALLET_ADDRESS or PRIVATE_KEY defined in .env');
    console.log('    Add one to check a balance.');
    console.log('======================================================\n');
    return;
  }

  console.log(`\n[>] Address        : ${address}`);
  console.log(`    ${addressUrl(address)}`);

  try {
    // Arc exposes the same balance twice. Read both and show that they agree, because getting
    // this wrong by a factor of 1e12 is the most common way to misread an Arc balance.
    const [native, erc20] = await Promise.all([
      client.getBalance({ address }),
      client.readContract({ address: USDC_ERC20, abi: USDC_ABI, functionName: 'balanceOf', args: [address] }),
    ]);

    const remainder = native % SCALE;

    console.log('\n    --- the same balance, both of Arc\'s views ---');
    console.log(`    native  (${NATIVE_DECIMALS} dec) : ${formatUnits(native, NATIVE_DECIMALS)} USDC   [raw ${native}]`);
    console.log(`    ERC-20  ( ${ERC20_DECIMALS} dec) : ${formatUnits(erc20, ERC20_DECIMALS)} USDC   [raw ${erc20}]`);
    console.log(`    relation           : floor(native / 1e12) == ERC-20  ->  ${native / SCALE === erc20 ? 'OK' : 'MISMATCH'}`);
    console.log(`    truncated remainder: ${remainder} native units (< 1e12, i.e. under 0.000001 USDC)`);

    if (native === 0n) {
      console.log('\n[!] Balance is 0. To deploy on Arc Mainnet, bridge USDC to:');
      console.log(`    ${address}`);
    } else {
      console.log('\n[ok] Wallet is funded.');
    }
  } catch (err) {
    console.error(`[x] Error querying balance: ${err.shortMessage || err.message}`);
    process.exitCode = 1;
  }
  console.log('======================================================\n');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
