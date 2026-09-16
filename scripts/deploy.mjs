import { createWalletClient, createPublicClient, fallback, http, formatUnits } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import fs from 'fs';
import path from 'path';
import dotenv from 'dotenv';
import {
  arcMainnet,
  ARC_RPC_URLS,
  NATIVE_DECIMALS,
  addressUrl,
  txUrl,
} from './arc-chain.mjs';

dotenv.config();

/** Refuse to deploy unless the balance covers this multiple of the estimated cost. */
const SAFETY_MARGIN = 3n;

const fmt = (wei) => `${formatUnits(wei, NATIVE_DECIMALS)} USDC`;

async function main() {
  console.log('\n======================================================');
  console.log('       ARC MAINNET - CONTRACT DEPLOYMENT              ');
  console.log('======================================================');

  if (!process.env.PRIVATE_KEY) {
    console.error('\n[x] No PRIVATE_KEY in .env. Copy .env.example to .env and set it.');
    process.exit(1);
  }

  const rawKey = process.env.PRIVATE_KEY.trim();
  const account = privateKeyToAccount(rawKey.startsWith('0x') ? rawKey : `0x${rawKey}`);

  const transport = fallback(ARC_RPC_URLS.map((url) => http(url)));
  const publicClient = createPublicClient({ chain: arcMainnet, transport });
  const walletClient = createWalletClient({ account, chain: arcMainnet, transport });

  const chainId = await publicClient.getChainId();
  if (chainId !== arcMainnet.id) {
    console.error(`\n[x] RPC reports chain ${chainId}, expected ${arcMainnet.id} (Arc Mainnet). Aborting.`);
    process.exit(1);
  }

  console.log(`[+] Deployer       : ${account.address}`);
  console.log(`[+] Chain          : ${chainId}`);
  // Spell out the endpoint: a local fork of Arc also reports chain 5042, and a deployment banner
  // that says "Arc Mainnet" either way is how a fork run gets mistaken for the real thing.
  console.log(`[+] RPC            : ${ARC_RPC_URLS[0]}`);

  const artifactPath = path.resolve('scripts/ArcAgentGateway.json');
  if (!fs.existsSync(artifactPath)) {
    console.error(`[x] Artifact not found at ${artifactPath}. Run "npm run sync-artifact" first.`);
    process.exit(1);
  }
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
  const bytecode = artifact.bytecode.startsWith('0x') ? artifact.bytecode : `0x${artifact.bytecode}`;
  console.log(`[+] Bytecode       : ${(bytecode.length - 2) / 2} bytes`);

  // Price the deployment before spending anything. Arc's native asset is 18 decimals, so a
  // balance check that assumes 6 would pass on a wallet holding a millionth of what it needs.
  const [balance, gasPrice, gas] = await Promise.all([
    publicClient.getBalance({ address: account.address }),
    publicClient.getGasPrice(),
    publicClient.estimateGas({ account: account.address, data: bytecode }),
  ]);
  const cost = gas * gasPrice;

  console.log(`[+] Balance        : ${fmt(balance)}`);
  console.log(`[+] Estimated gas  : ${gas.toLocaleString('en-US')} units @ ${formatUnits(gasPrice, 9)} gwei`);
  console.log(`[+] Estimated cost : ${fmt(cost)}`);

  if (balance < cost * SAFETY_MARGIN) {
    console.error(`\n[x] Insufficient balance on Arc Mainnet.`);
    console.error(`    Have ${fmt(balance)}, want at least ${fmt(cost * SAFETY_MARGIN)} (${SAFETY_MARGIN}x the estimate, to absorb gas volatility).`);
    console.error(`    Fund ${account.address} with USDC on Arc, then rerun.`);
    console.log('======================================================\n');
    process.exit(1);
  }

  console.log('\n[..] Sending deployment transaction...');
  const hash = await walletClient.deployContract({ abi: artifact.abi, bytecode });
  console.log(`[+] Tx hash        : ${hash}`);
  console.log(`    ${txUrl(hash)}`);
  console.log('[..] Waiting for confirmation...');

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') {
    console.error(`\n[x] Deployment reverted. Receipt status: ${receipt.status}`);
    process.exit(1);
  }

  const deployedAddress = receipt.contractAddress;
  const actualCost = receipt.gasUsed * receipt.effectiveGasPrice;

  // Confirm there is really code at the address rather than trusting the receipt alone.
  const code = await publicClient.getBytecode({ address: deployedAddress });
  if (!code || code === '0x') {
    console.error(`\n[x] No bytecode at ${deployedAddress} after deployment. Aborting.`);
    process.exit(1);
  }

  console.log('\n======================================================');
  console.log(`  DEPLOYED VIA ${ARC_RPC_URLS[0]}`);
  console.log('======================================================');
  console.log(`[+] Contract       : ${deployedAddress}`);
  console.log(`    ${addressUrl(deployedAddress)}`);
  console.log(`[+] Block          : #${receipt.blockNumber}`);
  console.log(`[+] Gas used       : ${receipt.gasUsed.toLocaleString('en-US')}`);
  console.log(`[+] Actual cost    : ${fmt(actualCost)}`);
  console.log(`[+] Runtime code   : ${(code.length - 2) / 2} bytes`);

  const deploymentInfo = {
    contractAddress: deployedAddress,
    chainId: arcMainnet.id,
    deployer: account.address,
    transactionHash: hash,
    blockNumber: receipt.blockNumber.toString(),
    gasUsed: receipt.gasUsed.toString(),
    deploymentCostNative: actualCost.toString(),
    deployedAt: new Date().toISOString(),
    explorer: addressUrl(deployedAddress),
  };

  fs.writeFileSync(
    path.resolve('frontend/src/contracts/deployedAddress.json'),
    `${JSON.stringify(deploymentInfo, null, 2)}\n`
  );
  console.log('\n[+] Wrote frontend/src/contracts/deployedAddress.json');
  console.log('\nNext: npm run seed   (register demo services + one real paid call)');
  console.log('======================================================\n');
}

main().catch((err) => {
  console.error(`\n[x] Deployment failed: ${err.shortMessage || err.message}`);
  process.exit(1);
});
