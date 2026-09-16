import React, { useState, useEffect, useCallback } from 'react';
import {
  Wallet,
  Send,
  ShieldCheck,
  ExternalLink,
  Coins,
  Sparkles,
  RefreshCw,
  CheckCircle2,
  AlertTriangle,
  Lock,
  Layers,
  Terminal,
  Zap,
} from 'lucide-react';
import { encodeFunctionData, formatUnits, parseUnits, keccak256, toHex } from 'viem';
import deployedAddressInfo from './contracts/deployedAddress.json';
import contractArtifact from './contracts/ArcAgentGateway.json';
import {
  ARC_CHAIN_ID,
  ARC_EXPLORER,
  ARC_RPC_URLS,
  ARC_WALLET_PARAMS,
  ERC20_DECIMALS,
  NATIVE_DECIMALS,
  SCALE,
  USDC_ABI,
  USDC_ERC20,
  addressUrl,
  formatNative,
  publicClient,
  txUrl,
} from './arc';

const abi = contractArtifact.abi;
const contractAddress = deployedAddressInfo?.contractAddress || '';

/** A funded Arc validator, used to demonstrate the decimal relationship before you connect. */
const SAMPLE_ADDRESS = '0x5ACCC00D7e4dB975CCbfC2801bC9447f37198797';

export default function App() {
  const [activeTab, setActiveTab] = useState('paywall');
  const [blockHeight, setBlockHeight] = useState(null);
  const [gasPrice, setGasPrice] = useState(null);
  const [rpcLatency, setRpcLatency] = useState(null);
  const [account, setAccount] = useState(null);
  const [nativeBalance, setNativeBalance] = useState(null);
  const [erc20Balance, setErc20Balance] = useState(null);
  const [isArcChain, setIsArcChain] = useState(false);
  const [txLoading, setTxLoading] = useState(false);
  const [txSuccess, setTxSuccess] = useState(null);
  const [txError, setTxError] = useState(null);

  const [services, setServices] = useState([]);
  const [servicesError, setServicesError] = useState(null);

  const [escrowWorker, setEscrowWorker] = useState('');
  const [escrowAmount, setEscrowAmount] = useState('0.05');
  const [escrowTask, setEscrowTask] = useState('DEX Arbitrage Path Computation');

  const [proofAddress, setProofAddress] = useState(SAMPLE_ADDRESS);
  const [proof, setProof] = useState(null);
  const [proofError, setProofError] = useState(null);

  // ---------------------------------------------------------------- chain head

  const fetchHead = useCallback(async () => {
    try {
      const start = Date.now();
      const [block, price] = await Promise.all([
        publicClient.getBlockNumber(),
        publicClient.getGasPrice(),
      ]);
      setBlockHeight(block);
      setGasPrice(price);
      setRpcLatency(Date.now() - start);
    } catch (err) {
      console.error('[ArcPay] RPC head query failed', err);
    }
  }, []);

  useEffect(() => {
    fetchHead();
    const interval = setInterval(fetchHead, 4000);
    return () => clearInterval(interval);
  }, [fetchHead]);

  // ------------------------------------------------------- on-chain registry

  const loadServices = useCallback(async () => {
    if (!contractAddress) return;
    try {
      const count = await publicClient.readContract({
        address: contractAddress, abi, functionName: 'getServiceCount',
      });
      const ids = Array.from({ length: Number(count) }, (_, i) => BigInt(i + 1));
      const rows = await Promise.all(
        ids.map((id) => publicClient.readContract({
          address: contractAddress, abi, functionName: 'services', args: [id],
        }))
      );
      setServices(rows.map((r) => ({
        id: r[0], provider: r[1], name: r[2], endpoint: r[3],
        fee: r[4], active: r[5], totalCalls: r[6], totalRevenue: r[7],
      })));
      setServicesError(null);
    } catch (err) {
      console.error('[ArcPay] registry read failed', err);
      setServicesError(err.shortMessage || err.message);
    }
  }, []);

  useEffect(() => { loadServices(); }, [loadServices]);

  // --------------------------------------------------------- decimals proof

  const loadProof = useCallback(async (address) => {
    if (!address || !/^0x[0-9a-fA-F]{40}$/.test(address)) {
      setProofError('Enter a valid 0x address.');
      setProof(null);
      return;
    }
    try {
      const [native, erc20] = await Promise.all([
        publicClient.getBalance({ address }),
        publicClient.readContract({ address: USDC_ERC20, abi: USDC_ABI, functionName: 'balanceOf', args: [address] }),
      ]);
      setProof({ address, native, erc20, remainder: native % SCALE, matches: native / SCALE === erc20 });
      setProofError(null);
    } catch (err) {
      setProofError(err.shortMessage || err.message);
      setProof(null);
    }
  }, []);

  useEffect(() => { loadProof(SAMPLE_ADDRESS); }, [loadProof]);

  // ------------------------------------------------------------------ wallet

  const refreshAccountState = useCallback(async (addr) => {
    if (!addr || !window.ethereum) return;
    try {
      const chainId = await window.ethereum.request({ method: 'eth_chainId' });
      setIsArcChain(parseInt(chainId, 16) === ARC_CHAIN_ID);
      const [native, erc20] = await Promise.all([
        publicClient.getBalance({ address: addr }),
        publicClient.readContract({ address: USDC_ERC20, abi: USDC_ABI, functionName: 'balanceOf', args: [addr] }),
      ]);
      setNativeBalance(native);
      setErc20Balance(erc20);
    } catch (err) {
      console.error('[ArcPay] account refresh failed', err);
    }
  }, []);

  const connectWallet = async () => {
    if (!window.ethereum) {
      setTxError('No Web3 wallet detected. Install MetaMask or a compatible wallet.');
      return;
    }
    try {
      const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
      setAccount(accounts[0]);
      setProofAddress(accounts[0]);
      await refreshAccountState(accounts[0]);
      await loadProof(accounts[0]);
    } catch (err) {
      setTxError(err.message);
    }
  };

  useEffect(() => {
    if (!window.ethereum) return undefined;
    const onAccounts = (accounts) => {
      setAccount(accounts[0] || null);
      if (accounts[0]) refreshAccountState(accounts[0]);
    };
    const onChain = () => { if (account) refreshAccountState(account); };
    window.ethereum.on?.('accountsChanged', onAccounts);
    window.ethereum.on?.('chainChanged', onChain);
    return () => {
      window.ethereum.removeListener?.('accountsChanged', onAccounts);
      window.ethereum.removeListener?.('chainChanged', onChain);
    };
  }, [account, refreshAccountState]);

  const switchToArc = async () => {
    if (!window.ethereum) return;
    try {
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: ARC_WALLET_PARAMS.chainId }],
      });
    } catch (switchError) {
      if (switchError.code === 4902) {
        await window.ethereum.request({ method: 'wallet_addEthereumChain', params: [ARC_WALLET_PARAMS] });
      } else {
        setTxError(switchError.message);
        return;
      }
    }
    if (account) refreshAccountState(account);
  };

  // ------------------------------------------------------------ transactions

  const requireReady = () => {
    if (!account) throw new Error('Connect a wallet first.');
    if (!isArcChain) throw new Error(`Switch to Arc Mainnet (chain ID ${ARC_CHAIN_ID}).`);
    if (!contractAddress) throw new Error('Contract is not deployed yet. Run "npm run deploy".');
  };

  /**
   * Pay a registered service. This encodes a real `payForService(uint256,bytes32)` call — a bare
   * value transfer would land in `receive()` and leave the registry counters untouched.
   */
  const handlePayService = async (service) => {
    setTxLoading(true); setTxSuccess(null); setTxError(null);
    try {
      requireReady();
      const data = encodeFunctionData({
        abi,
        functionName: 'payForService',
        // Stands in for the hash of the request payload an agent would actually be paying for.
        // Anchored to the current block so repeated calls produce distinct, traceable hashes.
        args: [service.id, keccak256(toHex(`arcpay:${service.id}:${service.name}:${blockHeight ?? 0n}`))],
      });
      const hash = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{ from: account, to: contractAddress, value: `0x${service.fee.toString(16)}`, data }],
      });
      setTxSuccess({ hash, label: `payForService(${service.id}) — ${service.name}`, amount: formatNative(service.fee) });
      await publicClient.waitForTransactionReceipt({ hash });
      await Promise.all([loadServices(), refreshAccountState(account), loadProof(account)]);
    } catch (err) {
      setTxError(err.shortMessage || err.message || 'Transaction failed');
    } finally {
      setTxLoading(false);
    }
  };

  /** Lock funds in escrow with a real `createEscrow(address,bytes32,uint256)` call. */
  const handleCreateEscrow = async () => {
    setTxLoading(true); setTxSuccess(null); setTxError(null);
    try {
      requireReady();
      if (!/^0x[0-9a-fA-F]{40}$/.test(escrowWorker)) throw new Error('Worker must be a valid 0x address.');
      const value = parseUnits(escrowAmount || '0', NATIVE_DECIMALS);
      if (value <= 0n) throw new Error('Escrow amount must be greater than zero.');
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
      const data = encodeFunctionData({
        abi,
        functionName: 'createEscrow',
        args: [escrowWorker, keccak256(toHex(escrowTask)), deadline],
      });
      const hash = await window.ethereum.request({
        method: 'eth_sendTransaction',
        params: [{ from: account, to: contractAddress, value: `0x${value.toString(16)}`, data }],
      });
      setTxSuccess({ hash, label: 'createEscrow — 1 hour deadline', amount: formatNative(value) });
      await publicClient.waitForTransactionReceipt({ hash });
      await Promise.all([refreshAccountState(account), loadProof(account)]);
    } catch (err) {
      setTxError(err.shortMessage || err.message || 'Transaction failed');
    } finally {
      setTxLoading(false);
    }
  };

  // ------------------------------------------------------------------ render

  const tabs = [
    { key: 'paywall', label: 'Pay-per-Call Registry', icon: Sparkles },
    { key: 'escrow', label: 'Autonomous Micro-Escrow', icon: Lock },
    { key: 'decimals', label: 'Decimals Proof (18 / 6)', icon: Coins },
  ];

  return (
    <div className="min-h-screen bg-[#07090E] text-slate-100 selection:bg-blue-500 selection:text-white font-sans">
      <div className="fixed inset-0 pointer-events-none bg-[radial-gradient(ellipse_80%_60%_at_50%_-20%,rgba(37,99,235,0.15),transparent_70%)]" />

      {/* Top banner */}
      <div className="border-b border-slate-800/80 bg-slate-950/60 backdrop-blur-md px-4 py-2 text-xs text-slate-400 flex flex-wrap justify-between items-center gap-2 relative">
        <div className="flex items-center space-x-3 flex-wrap gap-y-1">
          <span className="flex items-center gap-1.5 font-mono text-emerald-400">
            <span className="h-2 w-2 rounded-full bg-emerald-400 animate-ping inline-block" />
            Arc Mainnet Live
          </span>
          <span className="text-slate-600">|</span>
          <span>Chain ID <strong className="text-slate-200">{ARC_CHAIN_ID}</strong></span>
          <span className="text-slate-600">|</span>
          <span>Native gas <strong className="text-blue-400">USDC · {NATIVE_DECIMALS} decimals</strong></span>
          <span className="text-slate-600">|</span>
          <span>ERC-20 <strong className="text-blue-400">{ERC20_DECIMALS} decimals</strong></span>
        </div>
        <div className="flex items-center space-x-4 font-mono flex-wrap gap-y-1">
          <span>Block <strong className="text-slate-200">#{blockHeight?.toString() || '…'}</strong></span>
          {gasPrice !== null && <span>Gas <strong className="text-slate-200">{formatUnits(gasPrice, 9).slice(0, 6)} gwei</strong></span>}
          {rpcLatency !== null && <span>RPC <strong className="text-emerald-400">{rpcLatency}ms</strong></span>}
        </div>
      </div>

      {/* Header */}
      <header className="max-w-6xl mx-auto px-6 py-6 flex flex-wrap justify-between items-center border-b border-slate-800/50 gap-4 relative">
        <div className="flex items-center space-x-3">
          <div className="h-10 w-10 rounded-xl bg-gradient-to-tr from-blue-600 to-indigo-500 p-0.5 shadow-lg shadow-blue-500/20 flex items-center justify-center">
            <Zap className="h-5 w-5 text-white" />
          </div>
          <div>
            <h1 className="text-xl font-bold tracking-tight text-white flex items-center gap-2">
              ArcPay <span className="text-xs px-2 py-0.5 rounded-full bg-blue-500/10 border border-blue-500/30 text-blue-400">Agentic Gateway</span>
            </h1>
            <p className="text-xs text-slate-400">Native USDC micro-payments and escrow for agents on Arc</p>
          </div>
        </div>

        <div className="flex items-center space-x-3">
          {account ? (
            <div className="flex items-center gap-2 bg-slate-900 border border-slate-700/60 rounded-xl p-1.5 px-3">
              <div className="text-right mr-1">
                <div
                  className="text-xs font-mono font-medium text-emerald-400"
                  title={`native ${NATIVE_DECIMALS} dec: ${nativeBalance?.toString() ?? '—'} · ERC-20 ${ERC20_DECIMALS} dec: ${erc20Balance?.toString() ?? '—'}`}
                >
                  {formatNative(nativeBalance)} USDC
                </div>
                <div className="text-[10px] text-slate-400 font-mono">
                  {account.slice(0, 6)}…{account.slice(-4)}
                  {erc20Balance !== null && (
                    <span className="text-slate-500"> · erc20 {formatUnits(erc20Balance, ERC20_DECIMALS)}</span>
                  )}
                </div>
              </div>
              {!isArcChain ? (
                <button onClick={switchToArc} className="bg-amber-500/20 border border-amber-500/40 text-amber-300 text-xs px-2.5 py-1 rounded-lg hover:bg-amber-500/30 transition flex items-center gap-1">
                  <AlertTriangle className="w-3 h-3" /> Switch to Arc
                </button>
              ) : (
                <span className="text-[11px] bg-emerald-500/10 border border-emerald-500/30 text-emerald-400 px-2 py-0.5 rounded-md font-mono">Arc {ARC_CHAIN_ID}</span>
              )}
            </div>
          ) : (
            <button onClick={connectWallet} className="bg-blue-600 hover:bg-blue-500 text-white text-xs font-medium px-4 py-2 rounded-xl transition shadow-md shadow-blue-600/30 flex items-center gap-2">
              <Wallet className="w-4 h-4" /> Connect wallet
            </button>
          )}
        </div>
      </header>

      <main className="max-w-6xl mx-auto px-6 py-8 relative">
        {/* Contract status */}
        <div className="mb-8 p-4 rounded-2xl bg-slate-900/50 border border-slate-800 backdrop-blur flex flex-col md:flex-row justify-between items-start md:items-center gap-4">
          <div className="flex items-center gap-3">
            <div className={`p-2.5 rounded-xl ${contractAddress ? 'bg-emerald-500/10 text-emerald-400 border border-emerald-500/20' : 'bg-amber-500/10 text-amber-400 border border-amber-500/20'}`}>
              <Layers className="w-5 h-5" />
            </div>
            <div>
              <div className="text-sm font-semibold flex flex-wrap items-center gap-2">
                ArcAgentGateway
                {contractAddress
                  ? <span className="font-mono text-emerald-400 text-xs break-all">{contractAddress}</span>
                  : <span className="text-amber-400 text-xs">not deployed yet</span>}
              </div>
              <div className="text-xs text-slate-400 mt-0.5">
                {contractAddress
                  ? `Live on Arc Mainnet · deployed in block #${deployedAddressInfo.blockNumber}`
                  : 'Compiles and tests green. Run "npm run deploy" to publish it to Arc Mainnet.'}
              </div>
            </div>
          </div>
          <div className="flex items-center gap-2">
            {contractAddress ? (
              <a href={addressUrl(contractAddress)} target="_blank" rel="noreferrer" className="text-xs bg-slate-800 hover:bg-slate-700 text-slate-200 px-3 py-1.5 rounded-lg transition flex items-center gap-1.5 border border-slate-700">
                View on Arc Explorer <ExternalLink className="w-3 h-3" />
              </a>
            ) : (
              <div className="text-xs bg-slate-800/80 border border-slate-700 text-slate-300 font-mono px-3 py-1.5 rounded-lg flex items-center gap-2">
                <Terminal className="w-3 h-3 text-blue-400" /> npm run deploy
              </div>
            )}
          </div>
        </div>

        {/* Tabs */}
        <div className="flex border-b border-slate-800 mb-8 space-x-8 overflow-x-auto">
          {tabs.map(({ key, label, icon: Icon }) => (
            <button
              key={key}
              onClick={() => setActiveTab(key)}
              className={`pb-3 text-sm font-medium transition flex items-center gap-2 relative whitespace-nowrap ${activeTab === key ? 'text-blue-400' : 'text-slate-400 hover:text-slate-200'}`}
            >
              <Icon className="w-4 h-4" /> {label}
              {activeTab === key && <div className="absolute bottom-0 left-0 right-0 h-0.5 bg-blue-500 shadow-sm shadow-blue-500" />}
            </button>
          ))}
        </div>

        {/* Feedback */}
        {txSuccess && (
          <div className="mb-6 p-4 rounded-xl bg-emerald-500/10 border border-emerald-500/30 text-emerald-300 flex flex-wrap items-start justify-between gap-3">
            <div className="flex items-center gap-3">
              <CheckCircle2 className="w-5 h-5 text-emerald-400 shrink-0" />
              <div>
                <p className="text-sm font-semibold">Transaction sent</p>
                <p className="text-xs text-emerald-400/80 font-mono mt-0.5">{txSuccess.label} · {txSuccess.amount} USDC</p>
              </div>
            </div>
            <a href={txUrl(txSuccess.hash)} target="_blank" rel="noreferrer" className="text-xs text-emerald-300 underline font-mono flex items-center gap-1">
              View on Arc Explorer <ExternalLink className="w-3 h-3" />
            </a>
          </div>
        )}
        {txError && (
          <div className="mb-6 p-4 rounded-xl bg-red-500/10 border border-red-500/30 text-red-300 flex items-center gap-3">
            <AlertTriangle className="w-5 h-5 text-red-400 shrink-0" />
            <p className="text-xs break-all">{txError}</p>
          </div>
        )}

        {/* TAB: registry */}
        {activeTab === 'paywall' && (
          <div>
            <div className="mb-6">
              <h2 className="text-lg font-semibold text-white">Agent services, read from the on-chain registry</h2>
              <p className="text-xs text-slate-400 mt-1 max-w-3xl">
                Every card below is a live read of <code className="text-blue-400">services(uint256)</code> on the deployed
                contract, not a hardcoded list. Paying one encodes a real{' '}
                <code className="text-blue-400">payForService(uint256,bytes32)</code> call, so the call counter and the
                provider&apos;s claimable balance move on chain. Settlement is a plain{' '}
                <code className="text-blue-400">msg.value</code> transfer: USDC is the gas token here, so there is no
                ERC-20 approval round-trip.
              </p>
            </div>

            {!contractAddress && (
              <div className="p-6 rounded-2xl bg-slate-900/60 border border-slate-800 text-sm text-slate-400">
                The contract is not deployed yet, so the registry is empty. Run <code className="text-blue-400">npm run deploy</code> then <code className="text-blue-400">npm run seed</code>.
              </div>
            )}
            {servicesError && (
              <div className="p-4 rounded-xl bg-red-500/10 border border-red-500/30 text-red-300 text-xs mb-4">Registry read failed: {servicesError}</div>
            )}

            <div className="grid md:grid-cols-3 gap-6">
              {services.map((svc) => (
                <div key={svc.id.toString()} className="bg-slate-900/60 border border-slate-800 rounded-2xl p-5 hover:border-slate-700 transition flex flex-col justify-between group relative overflow-hidden">
                  <div className="absolute top-0 right-0 w-24 h-24 bg-blue-500/5 rounded-bl-full pointer-events-none group-hover:bg-blue-500/10 transition" />
                  <div>
                    <div className="flex justify-between items-center mb-3">
                      <span className="text-[10px] font-mono uppercase tracking-wider text-blue-400 bg-blue-500/10 px-2 py-0.5 rounded-md border border-blue-500/20">
                        service #{svc.id.toString()}
                      </span>
                      <span className={`flex items-center gap-1 text-[11px] font-mono ${svc.active ? 'text-emerald-400' : 'text-slate-500'}`}>
                        <span className={`w-1.5 h-1.5 rounded-full ${svc.active ? 'bg-emerald-400' : 'bg-slate-500'}`} />
                        {svc.active ? 'active' : 'paused'}
                      </span>
                    </div>
                    <h3 className="text-base font-semibold text-white group-hover:text-blue-400 transition">{svc.name}</h3>
                    <p className="text-[11px] text-slate-500 mt-2 font-mono break-all">{svc.endpoint}</p>
                    <div className="mt-3 grid grid-cols-2 gap-2 text-[11px] font-mono">
                      <div className="bg-slate-950/60 border border-slate-800 rounded-lg px-2 py-1.5">
                        <div className="text-slate-500">calls</div>
                        <div className="text-slate-200">{svc.totalCalls.toString()}</div>
                      </div>
                      <div className="bg-slate-950/60 border border-slate-800 rounded-lg px-2 py-1.5">
                        <div className="text-slate-500">revenue</div>
                        <div className="text-slate-200">{formatNative(svc.totalRevenue)}</div>
                      </div>
                    </div>
                  </div>

                  <div className="mt-6 pt-4 border-t border-slate-800/80">
                    <div className="flex justify-between items-center mb-3">
                      <span className="text-xs text-slate-400">Fee per call</span>
                      <span className="font-mono text-base font-bold text-white flex items-center gap-1">
                        {formatNative(svc.fee)} <span className="text-xs font-normal text-blue-400">USDC</span>
                      </span>
                    </div>
                    <button
                      onClick={() => handlePayService(svc)}
                      disabled={txLoading || !svc.active}
                      className="w-full bg-blue-600 hover:bg-blue-500 disabled:opacity-40 text-white text-xs font-medium py-2.5 rounded-xl transition shadow-md shadow-blue-600/20 flex items-center justify-center gap-2"
                    >
                      {txLoading ? <><RefreshCw className="w-3.5 h-3.5 animate-spin" /> Sending…</> : <><Send className="w-3.5 h-3.5" /> Pay &amp; invoke agent</>}
                    </button>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* TAB: escrow */}
        {activeTab === 'escrow' && (
          <div className="grid md:grid-cols-2 gap-8 items-start">
            <div className="bg-slate-900/60 border border-slate-800 rounded-2xl p-6">
              <h2 className="text-base font-semibold text-white flex items-center gap-2">
                <ShieldCheck className="w-5 h-5 text-blue-400" /> Create a multi-agent task escrow
              </h2>
              <p className="text-xs text-slate-400 mt-1 mb-6">
                Locks native USDC in <code className="text-blue-400">createEscrow</code> until the worker agent delivers,
                with an automatic refund path once the deadline passes. This signs a real transaction.
              </p>
              <div className="space-y-4">
                <div>
                  <label className="block text-xs font-medium text-slate-300 mb-1">Worker agent address</label>
                  <input
                    type="text" value={escrowWorker} placeholder="0x…"
                    onChange={(e) => setEscrowWorker(e.target.value.trim())}
                    className="w-full bg-slate-950 border border-slate-800 rounded-xl px-3 py-2 text-xs font-mono text-slate-200 focus:outline-none focus:border-blue-500"
                  />
                </div>
                <div>
                  <label className="block text-xs font-medium text-slate-300 mb-1">Amount (USDC, {NATIVE_DECIMALS} decimals on the wire)</label>
                  <div className="relative">
                    <input
                      type="number" step="0.001" min="0" value={escrowAmount}
                      onChange={(e) => setEscrowAmount(e.target.value)}
                      className="w-full bg-slate-950 border border-slate-800 rounded-xl px-3 py-2 text-xs font-mono text-slate-200 focus:outline-none focus:border-blue-500"
                    />
                    <span className="absolute right-3 top-2 text-xs text-slate-400 font-mono">USDC</span>
                  </div>
                  <p className="text-[10px] text-slate-500 mt-1 font-mono">
                    msg.value = {(() => { try { return parseUnits(escrowAmount || '0', NATIVE_DECIMALS).toString(); } catch { return '—'; } })()} native units
                  </p>
                </div>
                <div>
                  <label className="block text-xs font-medium text-slate-300 mb-1">Task description (hashed on chain)</label>
                  <input
                    type="text" value={escrowTask} onChange={(e) => setEscrowTask(e.target.value)}
                    className="w-full bg-slate-950 border border-slate-800 rounded-xl px-3 py-2 text-xs text-slate-200 focus:outline-none focus:border-blue-500"
                  />
                  <p className="text-[10px] text-slate-500 mt-1 font-mono break-all">keccak256 = {keccak256(toHex(escrowTask))}</p>
                </div>
                <div className="pt-2">
                  <button
                    onClick={handleCreateEscrow} disabled={txLoading}
                    className="w-full bg-blue-600 hover:bg-blue-500 disabled:opacity-40 text-white text-xs font-medium py-2.5 rounded-xl transition flex items-center justify-center gap-2"
                  >
                    {txLoading ? <><RefreshCw className="w-4 h-4 animate-spin" /> Sending…</> : <><Lock className="w-4 h-4" /> Lock in escrow</>}
                  </button>
                </div>
              </div>
            </div>

            <div className="bg-slate-900/60 border border-slate-800 rounded-2xl p-6">
              <h3 className="text-sm font-semibold text-white mb-3">On-chain lifecycle</h3>
              <div className="space-y-4 text-xs text-slate-300">
                {[
                  ['Locked', <>USDC sits in <code>ArcAgentGateway</code>. An <code>escrowId</code> is emitted by <code>EscrowCreated</code>.</>],
                  ['Settled', <>The worker calls <code>completeEscrow</code> with its result. Funds move to the worker&apos;s claimable balance — pull payment, never a push.</>],
                  ['Refunded', <>If the deadline passes untouched, the payer calls <code>refundEscrow</code> and recovers the full amount.</>],
                ].map(([title, body], i) => (
                  <div className="flex gap-3 items-start" key={title}>
                    <div className="w-6 h-6 rounded-full bg-blue-500/10 border border-blue-500/30 text-blue-400 flex items-center justify-center shrink-0 font-mono">{i + 1}</div>
                    <div><strong className="text-white">{title}:</strong> {body}</div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}

        {/* TAB: decimals proof */}
        {activeTab === 'decimals' && (
          <div className="max-w-4xl mx-auto space-y-6">
            <div className="bg-slate-900/60 border border-slate-800 rounded-2xl p-6">
              <h2 className="text-base font-semibold text-white mb-2">Arc stores one balance and shows it two ways</h2>
              <p className="text-xs text-slate-400 mb-4">
                Arc&apos;s native gas asset is USDC with <strong className="text-blue-400">18 decimals</strong> — that is what{' '}
                <code className="text-blue-400">msg.value</code> and <code className="text-blue-400">eth_getBalance</code> speak.
                The USDC ERC-20 predeploy at <code className="text-blue-400 break-all">{USDC_ERC20}</code> reports the same
                balance with <strong className="text-blue-400">6 decimals</strong>. The two are related by exactly{' '}
                <code className="text-blue-400">1e12</code>. Because USDC is a 6-decimal token on every other chain,
                assuming 6 here is the natural mistake — and it overstates every balance by a trillion.
                Check it against any address below; the numbers are read live from Arc Mainnet.
              </p>

              <div className="flex flex-wrap gap-2 mb-5">
                <input
                  type="text" value={proofAddress} onChange={(e) => setProofAddress(e.target.value.trim())}
                  className="flex-1 min-w-[280px] bg-slate-950 border border-slate-800 rounded-xl px-3 py-2 text-xs font-mono text-slate-200 focus:outline-none focus:border-blue-500"
                />
                <button onClick={() => loadProof(proofAddress)} className="bg-blue-600 hover:bg-blue-500 text-white text-xs font-medium px-4 py-2 rounded-xl transition">Read on chain</button>
              </div>

              {proofError && <p className="text-xs text-red-400 mb-3">{proofError}</p>}

              {proof && (
                <div className="space-y-3 font-mono text-xs">
                  <div className="bg-slate-950/60 border border-slate-800 rounded-xl p-4">
                    <div className="text-slate-500 mb-1">eth_getBalance — native, {NATIVE_DECIMALS} decimals</div>
                    <div className="text-emerald-400 text-sm break-all">{formatNative(proof.native, 18)} USDC</div>
                    <div className="text-slate-600 break-all mt-1">raw {proof.native.toString()}</div>
                  </div>
                  <div className="bg-slate-950/60 border border-slate-800 rounded-xl p-4">
                    <div className="text-slate-500 mb-1">balanceOf on {USDC_ERC20.slice(0, 10)}… — ERC-20, {ERC20_DECIMALS} decimals</div>
                    <div className="text-emerald-400 text-sm break-all">{formatUnits(proof.erc20, ERC20_DECIMALS)} USDC</div>
                    <div className="text-slate-600 break-all mt-1">raw {proof.erc20.toString()}</div>
                  </div>
                  <div className={`rounded-xl p-4 border ${proof.matches ? 'bg-emerald-500/10 border-emerald-500/30 text-emerald-300' : 'bg-red-500/10 border-red-500/30 text-red-300'}`}>
                    <div className="flex items-center gap-2 mb-1">
                      {proof.matches ? <CheckCircle2 className="w-4 h-4" /> : <AlertTriangle className="w-4 h-4" />}
                      <span className="font-semibold">floor(native / 1e12) == balanceOf → {proof.matches ? 'holds' : 'MISMATCH'}</span>
                    </div>
                    <div className="text-[11px] opacity-80">
                      truncated remainder: {proof.remainder.toString()} native units (&lt; 1e12, i.e. under 0.000001 USDC)
                    </div>
                  </div>
                  <div className="bg-slate-950/60 border border-slate-800 rounded-xl p-4">
                    <div className="text-slate-500 mb-1">the same balance misread as 6 decimals</div>
                    <div className="text-red-400 text-sm break-all">{formatUnits(proof.native, ERC20_DECIMALS)} USDC</div>
                    <div className="text-slate-600 mt-1">a factor of 1e12 too large</div>
                  </div>
                </div>
              )}
            </div>

            <div className="bg-slate-900/60 border border-slate-800 rounded-2xl p-6">
              <h3 className="text-sm font-semibold text-white mb-3">Reproduce it without this page</h3>
              <pre className="bg-slate-950/80 border border-slate-800 rounded-xl p-4 text-[11px] text-slate-300 overflow-x-auto"><code>{`# native balance, 18 decimals
curl -s ${ARC_RPC_URLS[0]} -H 'Content-Type: application/json' \\
  -d '{"jsonrpc":"2.0","method":"eth_getBalance","params":["${proof?.address || SAMPLE_ADDRESS}","latest"],"id":1}'

# same balance via the ERC-20 predeploy, 6 decimals
curl -s ${ARC_RPC_URLS[0]} -H 'Content-Type: application/json' \\
  -d '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"${USDC_ERC20}",
       "data":"0x70a08231000000000000000000000000${(proof?.address || SAMPLE_ADDRESS).slice(2)}"},"latest"],"id":1}'`}</code></pre>
              <p className="text-[11px] text-slate-500 mt-3">
                The repository also ships this as an executable assertion: <code className="text-blue-400">forge test</code> forks
                Arc Mainnet and checks the relationship against the live chain.
              </p>
            </div>
          </div>
        )}
      </main>

      <footer className="max-w-6xl mx-auto px-6 py-8 border-t border-slate-800/60 mt-12 flex flex-col md:flex-row justify-between items-center text-xs text-slate-500 gap-4 relative">
        <div>ArcPay · native USDC rails for the agentic economy on Arc</div>
        <div className="flex items-center space-x-6">
          <a href="https://docs.arc.network" target="_blank" rel="noreferrer" className="hover:text-slate-300">Arc docs</a>
          <a href={ARC_EXPLORER} target="_blank" rel="noreferrer" className="hover:text-slate-300">Arc Explorer</a>
        </div>
      </footer>
    </div>
  );
}
