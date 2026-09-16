/**
 * Bring the freshly deployed gateway to life on Arc Mainnet.
 *
 * A grant reviewer opening an empty contract learns nothing. This registers three demo agent
 * services in the on-chain registry, then actually pays one of them and withdraws the proceeds,
 * so that `getServiceCount()`, `totalCalls` and `totalRevenue` all read non-zero on chain.
 */
import { createWalletClient, createPublicClient, fallback, http, formatUnits, keccak256, toHex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import fs from 'fs';
import path from 'path';
import dotenv from 'dotenv';
import { arcMainnet, ARC_RPC_URLS, NATIVE_DECIMALS, addressUrl, txUrl } from './arc-chain.mjs';

dotenv.config();

const fmt = (wei) => `${formatUnits(wei, NATIVE_DECIMALS)} USDC`;

/** Fees in native units (18 decimals). 1e15 == 0.001 USDC. */
const SERVICES = [
  {
    name: 'Arc Arbitrage Sentinel',
    endpoint: 'https://agents.arcpay.dev/v1/arbitrage-sentinel',
    fee: 10_000_000_000_000_000n, // 0.01 USDC
  },
  {
    name: 'Autonomous Risk & Slippage Oracle',
    endpoint: 'https://agents.arcpay.dev/v1/slippage-oracle',
    fee: 5_000_000_000_000_000n, // 0.005 USDC
  },
  {
    name: 'Zero-Latency Gas Predictor',
    endpoint: 'https://agents.arcpay.dev/v1/gas-predictor',
    fee: 2_000_000_000_000_000n, // 0.002 USDC
  },
];

async function main() {
  if (!process.env.PRIVATE_KEY) {
    console.error('[x] No PRIVATE_KEY in .env.');
    process.exit(1);
  }

  const deploymentPath = path.resolve('frontend/src/contracts/deployedAddress.json');
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));
  if (!deployment.contractAddress) {
    console.error('[x] No contractAddress in deployedAddress.json. Run "npm run deploy" first.');
    process.exit(1);
  }
  const address = deployment.contractAddress;
  const artifact = JSON.parse(fs.readFileSync(path.resolve('scripts/ArcAgentGateway.json'), 'utf8'));
  const abi = artifact.abi;

  const rawKey = process.env.PRIVATE_KEY.trim();
  const account = privateKeyToAccount(rawKey.startsWith('0x') ? rawKey : `0x${rawKey}`);
  const transport = fallback(ARC_RPC_URLS.map((url) => http(url)));
  const publicClient = createPublicClient({ chain: arcMainnet, transport });
  const walletClient = createWalletClient({ account, chain: arcMainnet, transport });

  console.log('\n======================================================');
  console.log('       ARC MAINNET - SEEDING AGENT REGISTRY           ');
  console.log('======================================================');
  console.log(`[+] Contract : ${address}`);
  console.log(`    ${addressUrl(address)}`);
  console.log(`[+] Sender   : ${account.address}`);

  const existing = await publicClient.readContract({ address, abi, functionName: 'getServiceCount' });
  console.log(`[+] Services already registered: ${existing}`);

  const receipts = [];

  for (const [i, service] of SERVICES.entries()) {
    if (BigInt(i) < existing) {
      console.log(`[=] Service ${i + 1} already present, skipping.`);
      continue;
    }
    console.log(`\n[..] registerService("${service.name}", fee ${fmt(service.fee)})`);
    const hash = await walletClient.writeContract({
      address,
      abi,
      functionName: 'registerService',
      args: [service.name, service.endpoint, service.fee],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error(`registerService reverted: ${hash}`);
    console.log(`[+] ${txUrl(hash)}`);
    receipts.push({ step: `registerService:${service.name}`, hash });
  }

  // Pay for service 1 for real, so totalCalls and totalRevenue are non-zero on chain.
  const [, , , , fee] = await publicClient.readContract({ address, abi, functionName: 'services', args: [1n] });
  console.log(`\n[..] payForService(1) with ${fmt(fee)}`);
  const payHash = await walletClient.writeContract({
    address,
    abi,
    functionName: 'payForService',
    args: [1n, keccak256(toHex('arcpay:seed:first-agent-call'))],
    value: fee,
  });
  const payReceipt = await publicClient.waitForTransactionReceipt({ hash: payHash });
  if (payReceipt.status !== 'success') throw new Error(`payForService reverted: ${payHash}`);
  console.log(`[+] ${txUrl(payHash)}`);
  receipts.push({ step: 'payForService:1', hash: payHash });

  // Withdraw the accrued revenue, exercising the pull-payment path end to end.
  const claimable = await publicClient.readContract({
    address, abi, functionName: 'claimableBalances', args: [account.address],
  });
  console.log(`\n[..] withdraw() claimable ${fmt(claimable)}`);
  const wHash = await walletClient.writeContract({ address, abi, functionName: 'withdraw' });
  const wReceipt = await publicClient.waitForTransactionReceipt({ hash: wHash });
  if (wReceipt.status !== 'success') throw new Error(`withdraw reverted: ${wHash}`);
  console.log(`[+] ${txUrl(wHash)}`);
  receipts.push({ step: 'withdraw', hash: wHash });

  // Read the final on-chain state back rather than assuming the writes landed as intended.
  const count = await publicClient.readContract({ address, abi, functionName: 'getServiceCount' });
  const [, , name, , svcFee, active, totalCalls, totalRevenue] =
    await publicClient.readContract({ address, abi, functionName: 'services', args: [1n] });

  console.log('\n======================================================');
  console.log('  ON-CHAIN STATE AFTER SEEDING');
  console.log('======================================================');
  console.log(`[+] getServiceCount()      : ${count}`);
  console.log(`[+] services(1).name       : ${name}`);
  console.log(`[+] services(1).fee        : ${fmt(svcFee)}`);
  console.log(`[+] services(1).active     : ${active}`);
  console.log(`[+] services(1).totalCalls : ${totalCalls}`);
  console.log(`[+] services(1).totalRevenue: ${fmt(totalRevenue)}`);

  const out = { contractAddress: address, seededAt: new Date().toISOString(), transactions: receipts };
  fs.writeFileSync(path.resolve('frontend/src/contracts/seedTransactions.json'), `${JSON.stringify(out, null, 2)}\n`);
  console.log('\n[+] Wrote frontend/src/contracts/seedTransactions.json');
  console.log('======================================================\n');
}

main().catch((err) => {
  console.error(`\n[x] Seeding failed: ${err.shortMessage || err.message}`);
  process.exit(1);
});
