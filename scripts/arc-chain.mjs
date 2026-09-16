/**
 * Single source of truth for Arc Mainnet's chain parameters.
 *
 * The one thing worth spelling out: Arc's native gas asset is USDC with **18 decimals** at the
 * EVM level. The USDC ERC-20 predeploy at 0x3600...0000 uses 6. Both views read the same
 * balance, related by a factor of 1e12. Assuming 6 decimals for the native asset — a natural
 * mistake, since USDC is a 6-decimal token everywhere else — overstates every balance by
 * a trillion.
 */

export const ARC_RPC_URLS = [
  process.env.ARC_RPC_URL || 'https://rpc.mainnet.arc.io',
  'https://rpc.drpc.mainnet.arc.io',
  'https://rpc.quicknode.mainnet.arc.io',
];

export const ARC_EXPLORER = 'https://explorer.arc.io';

/** USDC ERC-20 predeploy. 6 decimals, and a 6-decimal view of the native balance. */
export const USDC_ERC20 = '0x3600000000000000000000000000000000000000';

/** Decimals of the native gas asset as seen by msg.value / eth_getBalance. */
export const NATIVE_DECIMALS = 18;

/** Decimals of the USDC ERC-20 predeploy. */
export const ERC20_DECIMALS = 6;

/** Ratio between the two representations. */
export const SCALE = 10n ** 12n;

export const arcMainnet = {
  id: 5042,
  name: 'Arc Mainnet',
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: NATIVE_DECIMALS },
  rpcUrls: {
    default: { http: ARC_RPC_URLS },
  },
  blockExplorers: {
    default: { name: 'Arc Explorer', url: ARC_EXPLORER },
  },
};

export const txUrl = (hash) => `${ARC_EXPLORER}/tx/${hash}`;
export const addressUrl = (address) => `${ARC_EXPLORER}/address/${address}`;

/** Minimal ABI for reading the USDC ERC-20 predeploy. */
export const USDC_ABI = [
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'decimals', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
  { type: 'function', name: 'totalSupply', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
];
