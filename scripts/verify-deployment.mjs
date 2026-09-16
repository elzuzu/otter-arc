/**
 * Check a deployed ArcAgentGateway against the live chain, from nothing but its address.
 *
 * This is the other half of the project's claim: the README says what the contract does and how
 * Arc denominates USDC, and this reads the deployment back and checks it. Anyone — a reviewer, a
 * future maintainer — can run it and see for themselves rather than taking the prose on trust.
 *
 *   npm run verify-deployment
 *   npm run verify-deployment -- 0xSomeOtherAddress
 */
import { createPublicClient, fallback, http, formatUnits } from 'viem';
import fs from 'fs';
import path from 'path';
import {
  arcMainnet, ARC_RPC_URLS, USDC_ERC20, USDC_ABI,
  NATIVE_DECIMALS, ERC20_DECIMALS, SCALE, addressUrl,
} from './arc-chain.mjs';

const client = createPublicClient({
  chain: arcMainnet,
  transport: fallback(ARC_RPC_URLS.map((url) => http(url))),
});

let failures = 0;
const check = (label, ok, detail) => {
  if (!ok) failures += 1;
  console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${label}${detail ? `  ${detail}` : ''}`);
};

async function main() {
  const artifact = JSON.parse(fs.readFileSync(path.resolve('scripts/ArcAgentGateway.json'), 'utf8'));
  const abi = artifact.abi;

  const override = process.argv[2];
  const deployment = JSON.parse(
    fs.readFileSync(path.resolve('frontend/src/contracts/deployedAddress.json'), 'utf8')
  );
  const address = override || deployment.contractAddress;

  console.log('\n======================================================');
  console.log('       ARC MAINNET - DEPLOYMENT VERIFICATION          ');
  console.log('======================================================');

  if (!address) {
    console.error('\n[x] No contract address. Deploy first, or pass one as an argument.');
    process.exit(1);
  }
  console.log(`[>] Contract : ${address}`);
  console.log(`    ${addressUrl(address)}\n`);

  const chainId = await client.getChainId();
  check('chain is Arc Mainnet (5042)', chainId === 5042, `got ${chainId}`);

  const code = await client.getBytecode({ address });
  check('contract has bytecode', !!code && code !== '0x', `${code ? (code.length - 2) / 2 : 0} bytes`);
  if (!code || code === '0x') {
    console.log('\nNothing deployed at that address.\n');
    process.exit(1);
  }

  const read = (functionName, args = []) => client.readContract({ address, abi, functionName, args });

  console.log('\n--- denomination, read from the contract itself ---');
  const [nativeDec, erc20Dec, scale, usdc, oneUsdc] = await Promise.all([
    read('NATIVE_DECIMALS'), read('ERC20_DECIMALS'), read('SCALE'), read('USDC_ERC20'), read('ONE_USDC'),
  ]);
  check('NATIVE_DECIMALS == 18', Number(nativeDec) === NATIVE_DECIMALS, `got ${nativeDec}`);
  check('ERC20_DECIMALS == 6', Number(erc20Dec) === ERC20_DECIMALS, `got ${erc20Dec}`);
  check('SCALE == 1e12', scale === SCALE, `got ${scale}`);
  check('USDC_ERC20 is the predeploy', usdc.toLowerCase() === USDC_ERC20.toLowerCase(), usdc);
  check('ONE_USDC == 1e18', oneUsdc === 10n ** 18n, `got ${oneUsdc}`);

  console.log('\n--- the contract agrees with the chain about a real balance ---');
  const sample = '0x5ACCC00D7e4dB975CCbfC2801bC9447f37198797';
  const [contractView, chainNative, chainErc20, predeployDecimals] = await Promise.all([
    read('nativeBalanceAsErc20', [sample]),
    client.getBalance({ address: sample }),
    client.readContract({ address: USDC_ERC20, abi: USDC_ABI, functionName: 'balanceOf', args: [sample] }),
    client.readContract({ address: USDC_ERC20, abi: USDC_ABI, functionName: 'decimals' }),
  ]);
  const [vNative, vErc20, vRemainder, vAvailable] = contractView;
  check('predeploy reports 6 decimals', Number(predeployDecimals) === 6, `got ${predeployDecimals}`);
  check('predeploy is reachable from the contract', vAvailable === true);
  check('contract native == eth_getBalance', vNative === chainNative, formatUnits(vNative, 18));
  check('contract erc20 == balanceOf', vErc20 === chainErc20, formatUnits(vErc20, 6));
  check('floor(native / 1e12) == erc20', chainNative / SCALE === chainErc20);
  check('remainder < 1e12', vRemainder < SCALE, `${vRemainder}`);

  console.log('\n--- the registry is alive, not just deployed ---');
  const count = await read('getServiceCount');
  check('at least one service registered', count > 0n, `${count}`);
  let calls = 0n;
  for (let i = 1n; i <= count && i <= 5n; i += 1n) {
    const s = await read('services', [i]);
    calls += s[6];
    console.log(`        service ${i}: "${s[2]}"  fee ${formatUnits(s[4], 18)}  calls ${s[6]}  revenue ${formatUnits(s[7], 18)}`);
  }
  check('at least one paid call has happened', calls > 0n, `${calls} total`);

  console.log('\n--- escrow safety properties are present in the deployed code ---');
  const names = abi.filter((e) => e.type === 'function').map((e) => e.name);
  for (const fn of [
    'submitResult', 'rejectResult', 'releaseEscrow', 'claimSubmittedEscrow', 'refundEscrow',
    'splitEscrow', 'reviewDeadline',
  ]) {
    check(`exposes ${fn}`, names.includes(fn));
  }
  check('no receive() fallback', !abi.some((e) => e.type === 'receive'));

  // createEscrow must carry the terms a worker prices a job on: the rejection budget and the
  // redo window are as much a safety surface as the functions above — earlier deployments
  // guaranteed a full-escrow win for junk regardless of what functions existed.
  const createEscrowAbi = abi.find((e) => e.type === 'function' && e.name === 'createEscrow');
  check('createEscrow takes 5 arguments (worker, taskHash, deadline, maxRejections, redoWindow)',
    !!createEscrowAbi && createEscrowAbi.inputs.length === 5,
    createEscrowAbi ? `got ${createEscrowAbi.inputs.length}` : 'not found');

  const [reviewWindow, claimWindow, maxRejections, maxTerm, maxRedoWindow] = await Promise.all([
    read('REVIEW_WINDOW'), read('CLAIM_WINDOW'), read('MAX_REJECTIONS'), read('MAX_TERM'), read('MAX_REDO_WINDOW'),
  ]);
  check('REVIEW_WINDOW is non-zero', reviewWindow > 0n, `${reviewWindow}s`);
  check('CLAIM_WINDOW is non-zero', claimWindow > 0n, `${claimWindow}s`);
  check('MAX_REJECTIONS is bounded and non-zero', maxRejections > 0n && maxRejections <= 10n, `${maxRejections}`);
  check('MAX_TERM is bounded', maxTerm > 0n, `${maxTerm}s (${Number(maxTerm) / 86400} days)`);
  check('MAX_REDO_WINDOW >= REVIEW_WINDOW', maxRedoWindow >= reviewWindow, `${maxRedoWindow}s`);

  console.log('\n======================================================');
  if (failures > 0) {
    console.error(`  ${failures} CHECK(S) FAILED`);
    console.log('======================================================\n');
    process.exit(1);
  }
  console.log('  ALL CHECKS PASSED');
  console.log('======================================================\n');
}

main().catch((err) => {
  console.error(`\n[x] Verification failed: ${err.shortMessage || err.message}`);
  process.exit(1);
});
