/**
 * Fill SUBMISSION.md's remaining placeholders from the actual deployment, and check it in.
 *
 * The only two things SUBMISSION.md cannot know ahead of a real deployment are the contract
 * address and its explorer link — everything else about ArcPay is already written. This turns
 * "go fill in the address by hand" into one command, run right after `npm run deploy` confirms.
 *
 *   npm run finalize-submission
 *
 * Refuses to run against an empty deployedAddress.json (nothing deployed yet), and refuses to
 * silently overwrite an address that was already filled in with a different one — it prints both
 * and asks you to resolve it, rather than guessing which is right.
 */
import fs from 'fs';
import path from 'path';
import { addressUrl } from './arc-chain.mjs';

const deployment = JSON.parse(
  fs.readFileSync(path.resolve('frontend/src/contracts/deployedAddress.json'), 'utf8')
);

if (!deployment.contractAddress) {
  console.error('[x] No contractAddress in deployedAddress.json. Run "npm run deploy" first.');
  process.exit(1);
}

const address = deployment.contractAddress;
const explorer = addressUrl(address);

const submissionPath = path.resolve('SUBMISSION.md');
let submission = fs.readFileSync(submissionPath, 'utf8');

const contractLine = /^Contract: .+$/m;
const explorerLine = /^Explorer: .+$/m;

const alreadyFilled = submission.match(/^Contract: (0x[0-9a-fA-F]{40})$/m);
if (alreadyFilled && alreadyFilled[1].toLowerCase() !== address.toLowerCase()) {
  console.error(`[x] SUBMISSION.md already names a different contract:`);
  console.error(`      in the file : ${alreadyFilled[1]}`);
  console.error(`      deployed now: ${address}`);
  console.error('    Resolve by hand — not overwriting automatically.');
  process.exit(1);
}

submission = submission
  .replace(contractLine, `Contract: ${address}`)
  .replace(explorerLine, `Explorer: ${explorer}`);

fs.writeFileSync(submissionPath, submission);

console.log('[+] SUBMISSION.md updated:');
console.log(`      Contract: ${address}`);
console.log(`      Explorer: ${explorer}`);
console.log('\nReview the diff, then commit and push:');
console.log('  git diff SUBMISSION.md');
console.log('  git add SUBMISSION.md && git commit -m "docs: fill in the deployed contract address" && git push');
