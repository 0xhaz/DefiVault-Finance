/**
 * Static protocol profiles for Shariah screening.
 *
 * These are pre-assessed flag sets for protocols the vault agent interacts with.
 * Each profile encodes the qualitative hard-exclude flags that cannot be derived
 * from on-chain data alone — they represent the agent's knowledge of how each
 * protocol operates.
 *
 * Profiles are the fallback when DefiLlama cannot provide ratio data.
 * They are NOT a substitute for board review (see disclaimer in engine.ts).
 */

import type { ProtocolData } from '../engine.ts';

// Partial profile — provides all boolean flags; ratio fields default to null
// when not overridden (triggers REVIEW on ratio screens, not FAIL).
type ProfileOverrides = Omit<ProtocolData, 'protocolName'>;

const BASE_CLEAN_PROFILE: ProfileOverrides = {
  debtToAssets:               null,
  nonCompliantRevenueRatio:   null,
  interestBearingAssetsRatio: null,
  hasRibaLending:             false,
  hasFundingRateIncome:       false,
  hasFrontRunning:            false,
  hasRibaSecurities:          false,
  hasMaisir:                  false,
  primaryActivityIsHalal:     true,
  goldExchangeIsAtomic:       null,
  lpIncomeIsSwapFeeOnly:      null,
};

export const PROTOCOL_PROFILES: Record<string, ProfileOverrides> = {
  // ── Permitted (Shariah vault) ──────────────────────────────────

  'uniswap-v3-usdc-eth': {
    ...BASE_CLEAN_PROFILE,
    nonCompliantRevenueRatio:   0.0,
    interestBearingAssetsRatio: 0.0,
    lpIncomeIsSwapFeeOnly:      true,
  },

  'uniswap-v3-usdc-paxg': {
    ...BASE_CLEAN_PROFILE,
    nonCompliantRevenueRatio:   0.0,
    interestBearingAssetsRatio: 0.0,
    lpIncomeIsSwapFeeOnly:      true,
  },

  'gold-exchange-paxg': {
    ...BASE_CLEAN_PROFILE,
    nonCompliantRevenueRatio:   0.0,
    interestBearingAssetsRatio: 0.0,
    goldExchangeIsAtomic:       true,
  },

  'gold-allocation-xaut': {
    ...BASE_CLEAN_PROFILE,
    nonCompliantRevenueRatio:   0.0,
    interestBearingAssetsRatio: 0.0,
    goldExchangeIsAtomic:       true,
    // Note: SR-008 board certification pending — use isPendingBoard flag in API layer.
  },

  'commodity-murabaha': {
    ...BASE_CLEAN_PROFILE,
    nonCompliantRevenueRatio:   0.0,
    interestBearingAssetsRatio: 0.0,
    // Murabaha: cost-plus disclosed sale — no lending, no interest, halal.
  },

  // ── Prohibited ────────────────────────────────────────────────

  'aave-v3': {
    ...BASE_CLEAN_PROFILE,
    hasRibaLending:             true,   // HX-001: interest-bearing lending
    nonCompliantRevenueRatio:   1.0,    // all revenue from lending = riba
    interestBearingAssetsRatio: 1.0,
    primaryActivityIsHalal:     false,
  },

  'compound-v3': {
    ...BASE_CLEAN_PROFILE,
    hasRibaLending:             true,   // HX-001
    nonCompliantRevenueRatio:   1.0,
    interestBearingAssetsRatio: 1.0,
    primaryActivityIsHalal:     false,
  },

  'ousg-ondo': {
    ...BASE_CLEAN_PROFILE,
    hasRibaSecurities:          true,   // HX-004: T-bill token — SR-001
    nonCompliantRevenueRatio:   1.0,
    interestBearingAssetsRatio: 1.0,
    primaryActivityIsHalal:     false,
  },

  'buidl-blackrock': {
    ...BASE_CLEAN_PROFILE,
    hasRibaSecurities:          true,   // HX-004: T-bill fund token — SR-001
    nonCompliantRevenueRatio:   1.0,
    interestBearingAssetsRatio: 1.0,
    primaryActivityIsHalal:     false,
  },

  'hyperliquid-eth-perp': {
    ...BASE_CLEAN_PROFILE,
    hasFundingRateIncome:       true,   // HX-002: perpetual funding rate
    hasMaisir:                  true,   // HX-005: speculative derivative
    nonCompliantRevenueRatio:   1.0,
    primaryActivityIsHalal:     false,
  },

  'stargate-bridge-frontrun': {
    ...BASE_CLEAN_PROFILE,
    hasFrontRunning:            true,   // HX-003: bridge flow front-running
    primaryActivityIsHalal:     false,
  },
};

/**
 * Build a ProtocolData object for a known protocol.
 * Returns null if the protocol slug is not in the static registry.
 */
export function buildProtocolData(slug: string): ProtocolData | null {
  const profile = PROTOCOL_PROFILES[slug];
  if (!profile) return null;
  return { protocolName: slug, ...profile };
}

/**
 * List all known protocol slugs.
 */
export function listKnownProtocols(): string[] {
  return Object.keys(PROTOCOL_PROFILES);
}
