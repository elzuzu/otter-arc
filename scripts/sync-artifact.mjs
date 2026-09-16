/**
 * Copy the freshly compiled contract artifact out of Foundry's build directory into the two
 * places that consume it: the deploy script and the frontend.
 *
 * This exists because both consumers previously held a hand-copied artifact, which silently
 * went stale the moment the contract changed — deploying old bytecode while the source read new.
 */
import fs from 'fs';
import path from 'path';

const CONTRACT = 'ArcAgentGateway';
const source = path.resolve(`contracts/out/${CONTRACT}.sol/${CONTRACT}.json`);

if (!fs.existsSync(source)) {
  console.error(`Artifact not found at ${source}. Run "npm test" or "forge build" in contracts/ first.`);
  process.exit(1);
}

const forgeArtifact = JSON.parse(fs.readFileSync(source, 'utf8'));
const bytecode = forgeArtifact.bytecode?.object;

if (!bytecode || bytecode === '0x') {
  console.error('Artifact contains no deployable bytecode.');
  process.exit(1);
}

const artifact = {
  abi: forgeArtifact.abi,
  bytecode,
};

const targets = [
  'scripts/ArcAgentGateway.json',
  'frontend/src/contracts/ArcAgentGateway.json',
];

for (const target of targets) {
  fs.mkdirSync(path.dirname(path.resolve(target)), { recursive: true });
  fs.writeFileSync(path.resolve(target), `${JSON.stringify(artifact, null, 2)}\n`);
  console.log(`[+] ${target}  (${artifact.abi.length} ABI entries, ${(bytecode.length - 2) / 2} bytes)`);
}
