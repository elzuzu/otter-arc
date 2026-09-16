import { createWalletClient, createPublicClient, http, formatUnits } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import fs from 'fs';
import path from 'path';
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

async function main() {
  console.log('\n======================================================');
  console.log('       ARC MAINNET - CONTRACT DEPLOYMENT              ');
  console.log('======================================================');

  if (!process.env.PRIVATE_KEY) {
    console.error('\n❌ ERREUR: Aucune clé privée trouvée dans le fichier .env !');
    console.error('👉 Veuillez copier le fichier .env.example en .env et renseigner PRIVATE_KEY=votre_cle_privee');
    console.log('======================================================\n');
    process.exit(1);
  }

  const rawKey = process.env.PRIVATE_KEY.trim();
  const formattedKey = rawKey.startsWith('0x') ? rawKey : `0x${rawKey}`;
  const account = privateKeyToAccount(formattedKey);

  const publicClient = createPublicClient({
    chain: arcMainnet,
    transport: http(),
  });

  const walletClient = createWalletClient({
    account,
    chain: arcMainnet,
    transport: http(),
  });

  console.log(`[+] Deployer Address : ${account.address}`);

  // Check balance
  const balance = await publicClient.getBalance({ address: account.address });
  const balanceUsdc = formatUnits(balance, 6);
  console.log(`[+] Native Gas Balance: ${balanceUsdc} USDC`);

  if (balance === 0n) {
    console.error('\n⚠️ SOLDE INSUFFISANT SUR ARC MAINNET !');
    console.error(`Le wallet ${account.address} possède 0 USDC sur Arc.`);
    console.error('Sur Arc, le gas est payé en USDC natif (avec 6 décimales).');
    console.error('\n👉 Envoyez simplement 1 ou 2 USDC sur cette adresse via Circle CCTP ou bridge Arc,');
    console.error('   puis relancez "npm run deploy" !');
    console.log('======================================================\n');
    process.exit(1);
  }

  // Load contract artifact
  const artifactPath = path.resolve('scripts/ArcAgentGateway.json');
  if (!fs.existsSync(artifactPath)) {
    console.error(`❌ Artifact not found at ${artifactPath}. Run 'npm test' or compile first.`);
    process.exit(1);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
  console.log('\n[⏳] Envoi de la transaction de déploiement sur Arc Mainnet...');

  const hash = await walletClient.deployContract({
    abi: artifact.abi,
    bytecode: artifact.bytecode.startsWith('0x') ? artifact.bytecode : `0x${artifact.bytecode}`,
  });

  console.log(`[+] Transaction Hash: ${hash}`);
  console.log('[⏳] En attente de confirmation de bloc...');

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  const deployedAddress = receipt.contractAddress;

  console.log('\n======================================================');
  console.log('🎉 FÉLICITATIONS ! DÉPLOIEMENT RÉUSSI SUR ARC MAINNET !');
  console.log('======================================================');
  console.log(`[✓] Adresse du contrat : ${deployedAddress}`);
  console.log(`[✓] Bloc confirmé       : #${receipt.blockNumber}`);
  console.log(`[✓] Explorateur Arc     : https://arcscan.app/address/${deployedAddress}`);
  console.log(`[✓] Tx sur ArcScan      : https://arcscan.app/tx/${hash}`);

  // Save deployed address for frontend
  const deploymentInfo = {
    contractAddress: deployedAddress,
    chainId: arcMainnet.id,
    deployer: account.address,
    transactionHash: hash,
    blockNumber: receipt.blockNumber.toString(),
    deployedAt: new Date().toISOString(),
  };

  fs.writeFileSync(
    path.resolve('frontend/src/contracts/deployedAddress.json'),
    JSON.stringify(deploymentInfo, null, 2)
  );
  console.log('\n[✓] Adresse enregistrée automatiquement dans frontend/src/contracts/deployedAddress.json');
  console.log('\nProchaines étapes :');
  console.log('1. Lancez le frontend : npm run dev');
  console.log('2. Déployez le frontend sur Vercel : npx vercel --prod');
  console.log('3. Soumettez votre candidature sur Arc House avec SUBMISSION.md !');
  console.log('======================================================\n');
}

main().catch((err) => {
  console.error('\n❌ Erreur lors du déploiement :', err.message);
  process.exit(1);
});
