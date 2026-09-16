/**
 * Fetch the external URLs referenced in the files listed below and fail on anything that does not
 * answer. This exists because the project shipped 11 references to `arcscan.app` across 5 files —
 * a domain that does not resolve at all. That is the kind of thing a reviewer discovers by
 * clicking and nobody discovers by reading.
 *
 * Scope is deliberately explicit rather than a repo-wide crawl: FILES below is the set that a
 * reader actually follows links from, and SKIP exempts placeholders and the illustrative agent
 * endpoints that are sample data rather than live services.
 */
import fs from 'fs';
import path from 'path';

const FILES = [
  'README.md',
  'SUBMISSION.md',
  'scripts/arc-chain.mjs',
  'scripts/deploy.mjs',
  'scripts/check-balance.mjs',
  'frontend/src/App.jsx',
  'contracts/src/ArcDecimals.sol',
  'contracts/src/ArcAgentGateway.sol',
  'frontend/src/arc.js',
  'contracts/test/ArcMainnetFork.t.sol',
  'contracts/README.md',
  'frontend/README.md',
];

/** Hosts we deliberately never probe: placeholders, or endpoints that reject bare GETs. */
const SKIP = [
  /^https?:\/\/localhost/,
  /^https?:\/\/127\.0\.0\.1/,
  /\[.*\]/,                       // markdown placeholders like https://[your-app].vercel.app
  /[<>]/,                         // angle-bracket placeholders like .../address/<CONTRACT>
  /your-?app|votre-|example\.com|YOUR_|FILL/i,
  /^https:\/\/agents\.arcpay\.dev/, // illustrative agent endpoints, not live services
  /^https:\/\/api\./,               // illustrative API endpoints in NatSpec examples
];

// Angle brackets are captured rather than treated as terminators, so that a placeholder such as
// `.../address/<CONTRACT>` is recognised as a placeholder and skipped, instead of being truncated
// to a bare `.../address/` that then reports a spurious 404.
const URL_RE = /https?:\/\/[^\s"'`)\]]+/g;

function collect() {
  const found = new Map();
  for (const file of FILES) {
    const full = path.resolve(file);
    if (!fs.existsSync(full)) continue;
    const text = fs.readFileSync(full, 'utf8');
    for (const raw of text.match(URL_RE) || []) {
      const url = raw.replace(/[.,;:>]+$/, ''); // trailing > closes a markdown autolink
      if (SKIP.some((re) => re.test(url))) continue;
      if (!found.has(url)) found.set(url, []);
      found.get(url).push(file);
    }
  }
  return found;
}

async function probe(url) {
  const isRpc = /rpc\./.test(url);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20000);
  try {
    if (isRpc) {
      // RPC endpoints 404 on GET; ask them something they answer.
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', method: 'eth_chainId', params: [], id: 1 }),
        signal: controller.signal,
      });
      const body = await res.json();
      return body.result ? { ok: true, note: `chainId ${parseInt(body.result, 16)}` } : { ok: false, note: 'no chainId' };
    }
    const res = await fetch(url, {
      method: 'GET',
      redirect: 'follow',
      headers: { 'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/147.0.0.0 Safari/537.36' },
      signal: controller.signal,
    });
    return { ok: res.status < 400, note: `HTTP ${res.status}` };
  } catch (err) {
    return { ok: false, note: err.name === 'AbortError' ? 'timeout' : err.message };
  } finally {
    clearTimeout(timer);
  }
}

const urls = collect();
console.log(`\nChecking ${urls.size} distinct URLs across ${FILES.length} files\n`);

const results = await Promise.all(
  [...urls.keys()].map(async (url) => ({ url, ...(await probe(url)) }))
);

let failed = 0;
for (const { url, ok, note } of results.sort((a, b) => a.url.localeCompare(b.url))) {
  if (!ok) failed += 1;
  console.log(`${ok ? ' ok ' : 'FAIL'}  ${note.padEnd(14)} ${url}`);
  if (!ok) console.log(`       referenced in: ${urls.get(url).join(', ')}`);
}

console.log(`\n${results.length - failed}/${results.length} reachable`);
if (failed > 0) {
  console.error(`\n${failed} dead link(s). Fix or remove them before publishing.`);
  process.exit(1);
}
