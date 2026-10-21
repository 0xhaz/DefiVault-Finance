/**
 * DefiLlama data source for Shariah screening ratio inputs.
 *
 * Fetches TVL, protocol metadata, and yield data from DefiLlama public API.
 * Raw responses are written to snapshots/ before any transformation.
 * CoinGecko raw data is never exposed in any API response per Task D spec.
 *
 * All network calls are isolated here — engine.ts has zero imports from this file.
 */

import * as fs from 'fs';
import * as path from 'path';

const DEFI_LLAMA_BASE = 'https://api.llama.fi'; // arc-studio-allow-onchain-literal
const SNAPSHOT_DIR = path.join(import.meta.dir, '..', 'snapshots');

// ─────────────────────────────────────────────────────────────────
// Snapshot writer — every fetch saves raw data to disk
// ─────────────────────────────────────────────────────────────────

function writeSnapshot(name: string, data: unknown): void {
  try {
    fs.mkdirSync(SNAPSHOT_DIR, { recursive: true });
    const ts = new Date().toISOString().replace(/[:.]/g, '-');
    const file = path.join(SNAPSHOT_DIR, `${name}-${ts}.json`);
    fs.writeFileSync(file, JSON.stringify(data, null, 2));
  } catch {
    // Snapshot write failure is non-fatal
  }
}

// ─────────────────────────────────────────────────────────────────
// DefiLlama protocol data
// ─────────────────────────────────────────────────────────────────

export interface DefiLlamaProtocol {
  name:          string;
  tvl:           number;
  category:      string;
  chains:        string[];
  description:   string;
}

export async function fetchProtocol(slug: string): Promise<DefiLlamaProtocol | null> {
  try {
    const res = await fetch(`${DEFI_LLAMA_BASE}/protocol/${slug}`, {
      signal: AbortSignal.timeout(6000),
    });
    if (!res.ok) return null;
    const data = await res.json() as DefiLlamaProtocol;
    writeSnapshot(`protocol-${slug}`, data);
    return data;
  } catch {
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────
// Yield data — pool APY from DefiLlama Yields API
// ─────────────────────────────────────────────────────────────────

export interface DefiLlamaPool {
  pool:     string;
  chain:    string;
  project:  string;
  symbol:   string;
  tvlUsd:   number;
  apy:      number;
  apyBase:  number | null;
  apyReward: number | null;
}

export async function fetchPools(projectSlug: string): Promise<DefiLlamaPool[]> {
  try {
    const res = await fetch(`${DEFI_LLAMA_BASE}/pools`, {
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) return [];
    const body = await res.json() as { data: DefiLlamaPool[] };
    const filtered = (body.data ?? []).filter(p => p.project === projectSlug);
    writeSnapshot(`pools-${projectSlug}`, filtered);
    return filtered;
  } catch {
    return [];
  }
}

// ─────────────────────────────────────────────────────────────────
// Simplified ratio extractor
//
// Attempts to derive screening-relevant ratios from DefiLlama data.
// Returns null for any metric it cannot confidently compute.
// Missing → REVIEW, not FAIL.
// ─────────────────────────────────────────────────────────────────

export interface ExtractedRatios {
  /** Estimated debt-to-assets from lending protocol data, or null. */
  debtToAssets:                number | null;
  /** Estimated non-compliant revenue ratio, or null. */
  nonCompliantRevenueRatio:    number | null;
  /** Estimated interest-bearing asset ratio, or null. */
  interestBearingAssetsRatio:  number | null;
  /** Source metadata for auditing. */
  source: string;
  timestamp: number;
}

export async function extractRatios(slug: string): Promise<ExtractedRatios> {
  const protocol = await fetchProtocol(slug);
  const base: ExtractedRatios = {
    debtToAssets:               null,
    nonCompliantRevenueRatio:   null,
    interestBearingAssetsRatio: null,
    source: `DefiLlama protocol/${slug}`,
    timestamp: Math.floor(Date.now() / 1000),
  };

  if (!protocol) return base;

  // DefiLlama does not expose debt/equity ratios directly.
  // For lending protocols (Aave, Compound), the entire TVL is collateral
  // backing interest-bearing loans — interestBearingAssetsRatio is treated
  // as effectively 1.0 (all assets are in interest-bearing use).
  const lendingCategories = ['Lending', 'CDP'];
  if (lendingCategories.includes(protocol.category)) {
    return {
      ...base,
      interestBearingAssetsRatio: 1.0,
      nonCompliantRevenueRatio:   1.0, // all revenue from lending = riba
    };
  }

  // DEX: swap fees only — compliant revenue ratio ≈ 0.
  const dexCategories = ['Dexes', 'DEX'];
  if (dexCategories.includes(protocol.category)) {
    return {
      ...base,
      nonCompliantRevenueRatio:   0.0,
      interestBearingAssetsRatio: 0.0,
    };
  }

  return base;
}
