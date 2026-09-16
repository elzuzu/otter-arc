/**
 * Arc Mainnet parameters for the browser.
 *
 * The one fact worth stating plainly: Arc's native gas asset is USDC with **18 decimals** at the
 * EVM level (`msg.value`, `eth_getBalance`), while the USDC ERC-20 predeploy at
 * 0x3600...0000 uses **6**. They are two views of a single balance, related by 1e12.
 * Declaring 6 here would make every wallet display a balance a trillion times too large.
 */
import { createPublicClient, fallback, http } from 'viem';

export const ARC_CHAIN_ID = 5042;

export const ARC_RPC_URLS = [
  'https://rpc.mainnet.arc.io',
  'https://rpc.drpc.mainnet.arc.io',
  'https://rpc.quicknode.mainnet.arc.io',
];

export const ARC_EXPLORER = 'https://explorer.arc.io';

export const USDC_ERC20 = '0x3600000000000000000000000000000000000000';

export const NATIVE_DECIMALS = 18;
export const ERC20_DECIMALS = 6;
export const SCALE = 10n ** 12n;

export const arcMainnet = {
  id: ARC_CHAIN_ID,
  name: 'Arc Mainnet',
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: NATIVE_DECIMALS },
  rpcUrls: { default: { http: ARC_RPC_URLS } },
  blockExplorers: { default: { name: 'Arc Explorer', url: ARC_EXPLORER } },
};

/** Shape expected by wallet_addEthereumChain. */
export const ARC_WALLET_PARAMS = {
  chainId: '0x13B2',
  chainName: 'Arc Mainnet',
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: NATIVE_DECIMALS },
  rpcUrls: [ARC_RPC_URLS[0]],
  blockExplorerUrls: [ARC_EXPLORER],
};

export const USDC_ABI = [
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'decimals', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
  { type: 'function', name: 'totalSupply', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
];

export const publicClient = createPublicClient({
  chain: arcMainnet,
  transport: fallback(ARC_RPC_URLS.map((url) => http(url))),
});

export const txUrl = (hash) => `${ARC_EXPLORER}/tx/${hash}`;
export const addressUrl = (address) => `${ARC_EXPLORER}/address/${address}`;

/** Format a native-denominated bigint for display, trimming to `places` decimals. */
export function formatNative(value, places = 6) {
  if (value === undefined || value === null) return '—';
  const whole = value / 10n ** BigInt(NATIVE_DECIMALS);
  const frac = (value % 10n ** BigInt(NATIVE_DECIMALS))
    .toString()
    .padStart(NATIVE_DECIMALS, '0')
    .slice(0, places);
  return `${whole}.${frac}`;
}
