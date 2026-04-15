#!/usr/bin/env node
/** Zero-dependency mock backend that mirrors the shape of the OCaml API
 *  so the Angular dev server can run without the OCaml side built.
 *
 *  Endpoints:
 *    GET  /api/indicators
 *    GET  /api/strategies
 *    GET  /api/candles?symbol=...&n=...
 *    POST /api/backtest
 *
 *  Run:  node mock-server.mjs   (or `npm run mock`)
 *
 *  Keeps the port and response shapes in sync with `lib/server/api.ml` +
 *  `lib/server/http.ml`. If those diverge, update here too. */

import { createServer } from 'node:http';

const PORT = Number(process.env.PORT ?? 8080);

// ─────────────────────────────────────────────────────────────────────────
// Catalogs — mirror lib/indicators/registry.ml and lib/strategies/registry.ml
// ─────────────────────────────────────────────────────────────────────────

const indicatorsCatalog = [
  { name: 'SMA',               params: [{ name: 'period', type: 'int',   default: 20 }] },
  { name: 'EMA',               params: [{ name: 'period', type: 'int',   default: 20 }] },
  { name: 'WMA',               params: [{ name: 'period', type: 'int',   default: 20 }] },
  { name: 'RSI',               params: [{ name: 'period', type: 'int',   default: 14 }] },
  { name: 'MACD',              params: [
      { name: 'fast',   type: 'int', default: 12 },
      { name: 'slow',   type: 'int', default: 26 },
      { name: 'signal', type: 'int', default:  9 },
  ]},
  { name: 'MACD-Weighted',     params: [
      { name: 'fast',   type: 'int', default: 12 },
      { name: 'slow',   type: 'int', default: 26 },
      { name: 'signal', type: 'int', default:  9 },
  ]},
  { name: 'BollingerBands',    params: [
      { name: 'period', type: 'int',   default: 20 },
      { name: 'k',      type: 'float', default:  2 },
  ]},
  { name: 'ATR',               params: [{ name: 'period', type: 'int', default: 14 }] },
  { name: 'OBV',               params: [] },
  { name: 'A/D',               params: [] },
  { name: 'ChaikinOscillator', params: [
      { name: 'fast', type: 'int', default:  3 },
      { name: 'slow', type: 'int', default: 10 },
  ]},
  { name: 'Stochastic',        params: [
      { name: 'k_period', type: 'int', default: 14 },
      { name: 'd_period', type: 'int', default:  3 },
  ]},
  { name: 'MFI', params: [{ name: 'period', type: 'int', default: 14 }] },
  { name: 'CMF', params: [{ name: 'period', type: 'int', default: 20 }] },
  { name: 'CVI', params: [{ name: 'period', type: 'int', default: 10 }] },
  { name: 'CVD', params: [] },
  { name: 'Volume',   params: [] },
  { name: 'VolumeMA', params: [{ name: 'period', type: 'int', default: 20 }] },
];

const strategiesCatalog = [
  { name: 'SMA_Crossover', params: [
      { name: 'fast',        type: 'int',  default: 10 },
      { name: 'slow',        type: 'int',  default: 30 },
      { name: 'allow_short', type: 'bool', default: false },
  ]},
  { name: 'RSI_MeanReversion', params: [
      { name: 'period',      type: 'int',   default: 14 },
      { name: 'lower',       type: 'float', default: 30 },
      { name: 'upper',       type: 'float', default: 70 },
      { name: 'exit_long',   type: 'float', default: 50 },
      { name: 'exit_short',  type: 'float', default: 50 },
      { name: 'allow_short', type: 'bool',  default: false },
  ]},
  { name: 'MACD_Momentum', params: [
      { name: 'fast',        type: 'int',  default: 12 },
      { name: 'slow',        type: 'int',  default: 26 },
      { name: 'signal',      type: 'int',  default:  9 },
      { name: 'allow_short', type: 'bool', default: false },
  ]},
  { name: 'Bollinger_Breakout', params: [
      { name: 'period',      type: 'int',   default: 20 },
      { name: 'k',           type: 'float', default:  2 },
      { name: 'allow_short', type: 'bool',  default: true },
  ]},
];

// ─────────────────────────────────────────────────────────────────────────
// Deterministic synthetic candle stream
// ─────────────────────────────────────────────────────────────────────────

/** Seeded mulberry32 so reloads with the same (symbol, n) return the
 *  same data — feels stable in the UI. */
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hash(str) {
  let h = 2166136261;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

/** Seconds-per-bar for each supported timeframe. Mirrors
 *  `Timeframe.to_seconds` in `lib/core/timeframe.ml`. */
const TIMEFRAME_SECONDS = {
  M1: 60, M5: 300, M15: 900, M30: 1800,
  H1: 3600, H4: 14400,
  D1: 86400, W1: 604800, MN1: 2592000,
};

function generateCandles({
  symbol = 'SBER', n = 500, timeframe = 'H1',
} = {}) {
  const tfSeconds = TIMEFRAME_SECONDS[timeframe] ?? 3600;
  const rng = mulberry32(hash(`${symbol}:${timeframe}:${n}`));
  const startTs = 1_704_067_200;   // 2024-01-01 UTC
  let price = 100 + rng() * 50;
  const out = [];
  for (let i = 0; i < n; i++) {
    const drift = (rng() * 2 - 1) * 0.6;
    const close = Math.max(1, price + drift);
    const high  = Math.max(price, close) + rng() * 0.7;
    const low   = Math.max(0.5, Math.min(price, close) - rng() * 0.7);
    const volume = 500 + Math.floor(rng() * 5000);
    out.push({
      ts: startTs + i * tfSeconds,
      open: round(price),
      high: round(high),
      low:  round(low),
      close: round(close),
      volume,
    });
    price = close;
  }
  return out;
}

const round = (x) => Math.round(x * 100) / 100;

// ─────────────────────────────────────────────────────────────────────────
// Plausible backtest result — just enough for the UI to render the panel
// ─────────────────────────────────────────────────────────────────────────

function runBacktest({ symbol, strategy, n = 500, timeframe = 'H1' }) {
  const candles = generateCandles({ symbol, n, timeframe });
  const rng = mulberry32(hash(`bt:${symbol}:${strategy}:${timeframe}:${n}`));
  const numTrades = 3 + Math.floor(rng() * 15);
  const totalReturn = (rng() * 0.3) - 0.05;   // -5% … +25%
  const maxDrawdown = rng() * 0.2;            //  0% … 20%
  const initialCash = 1_000_000;
  const finalCash = initialCash * (1 + totalReturn);
  const realizedPnl = finalCash - initialCash;

  // Fake equity curve: random walk anchored at initialCash ending near finalCash.
  const equityCurve = [];
  for (let i = 0; i < candles.length; i++) {
    const progress = i / (candles.length - 1);
    const noise = (rng() - 0.5) * initialCash * 0.03;
    equityCurve.push({
      ts: candles[i].ts,
      equity: initialCash + (finalCash - initialCash) * progress + noise,
    });
  }

  // Scatter a few synthetic fills.
  const fills = [];
  for (let i = 0; i < numTrades; i++) {
    const idx = Math.floor(rng() * candles.length);
    const c = candles[idx];
    fills.push({
      ts: c.ts,
      side: rng() > 0.5 ? 'BUY' : 'SELL',
      quantity: 100,
      price: c.close,
      fee: round(c.close * 100 * 0.0005),
      reason: `mock ${strategy} signal`,
    });
  }

  return {
    num_trades: numTrades,
    total_return: totalReturn,
    max_drawdown: maxDrawdown,
    final_cash: round(finalCash),
    realized_pnl: round(realizedPnl),
    equity_curve: equityCurve,
    fills,
  };
}

// ─────────────────────────────────────────────────────────────────────────
// HTTP wiring
// ─────────────────────────────────────────────────────────────────────────

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

function json(res, body, status = 200) {
  res.writeHead(status, { 'Content-Type': 'application/json', ...CORS });
  res.end(JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      try {
        const raw = Buffer.concat(chunks).toString('utf8');
        resolve(raw ? JSON.parse(raw) : {});
      } catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

const server = createServer(async (req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, CORS);
    res.end();
    return;
  }

  const url = new URL(req.url, `http://${req.headers.host}`);
  const path = url.pathname;

  try {
    if (req.method === 'GET' && path === '/api/indicators') {
      return json(res, indicatorsCatalog);
    }
    if (req.method === 'GET' && path === '/api/strategies') {
      return json(res, strategiesCatalog);
    }
    if (req.method === 'GET' && path === '/api/candles') {
      const symbol = url.searchParams.get('symbol') || 'SBER';
      const n = Number(url.searchParams.get('n') ?? 500);
      const timeframe = url.searchParams.get('timeframe') || 'H1';
      return json(res, { candles:
        generateCandles({ symbol, n, timeframe }) });
    }
    if (req.method === 'POST' && path === '/api/backtest') {
      const body = await readBody(req);
      return json(res, runBacktest(body));
    }
    if (req.method === 'GET' && (path === '/' || path === '/health')) {
      res.writeHead(200, { 'Content-Type': 'text/plain', ...CORS });
      res.end('mock ok');
      return;
    }
    res.writeHead(404, { 'Content-Type': 'text/plain', ...CORS });
    res.end('not found');
  } catch (e) {
    json(res, { error: String(e) }, 500);
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`mock-server: listening on http://127.0.0.1:${PORT}`);
  console.log('  GET  /api/indicators');
  console.log('  GET  /api/strategies');
  console.log('  GET  /api/candles?symbol=SBER&n=500');
  console.log('  POST /api/backtest   { symbol, strategy, params, n }');
});
