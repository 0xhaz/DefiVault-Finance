/**
 * SC Malaysia Shariah Screening Engine — unit tests
 *
 * Run: bun test server/screening/tests/engine.test.ts
 *
 * All tests call screen() directly — pure, no network calls.
 * Each hard-exclude rule has a fixture test producing FAIL with the correct rule ID.
 * RS-002 boundary: 0.0499 → PASS, 0.05 → REVIEW, 0.051 → FAIL.
 * Missing data → REVIEW on ratio screens.
 */

import { describe, test, expect } from 'bun:test';
import { screen, type ProtocolData } from '../engine.ts';

// ─────────────────────────────────────────────────────────────────
// Test helpers
// ─────────────────────────────────────────────────────────────────

function makeCleanData(overrides: Partial<ProtocolData> = {}): ProtocolData {
  return {
    protocolName:               'TestProtocol',
    debtToAssets:               0.1,
    nonCompliantRevenueRatio:   0.01,
    interestBearingAssetsRatio: 0.05,
    hasRibaLending:             false,
    hasFundingRateIncome:       false,
    hasFrontRunning:            false,
    hasRibaSecurities:          false,
    hasMaisir:                  false,
    primaryActivityIsHalal:     true,
    goldExchangeIsAtomic:       null,
    lpIncomeIsSwapFeeOnly:      null,
    ...overrides,
  };
}

function getRule(report: ReturnType<typeof screen>, ruleId: string) {
  const r = report.results.find(r => r.ruleId === ruleId);
  if (!r) throw new Error(`Rule ${ruleId} not found in report`);
  return r;
}

// ─────────────────────────────────────────────────────────────────
// Baseline: all-clean protocol passes everything
// ─────────────────────────────────────────────────────────────────

describe('baseline', () => {
  test('clean protocol returns PASS overall', () => {
    const report = screen(makeCleanData());
    expect(report.verdict).toBe('PASS');
  });

  test('report has 11 rule results', () => {
    const report = screen(makeCleanData());
    expect(report.results).toHaveLength(11);
  });

  test('report carries ruleVersion 1.0.0', () => {
    const report = screen(makeCleanData());
    expect(report.ruleVersion).toBe('1.0.0');
  });

  test('report carries non-empty disclaimer', () => {
    const report = screen(makeCleanData());
    expect(report.disclaimer.length).toBeGreaterThan(10);
  });

  test('report carries protocolName from input', () => {
    const report = screen(makeCleanData({ protocolName: 'UniswapV3' }));
    expect(report.protocolName).toBe('UniswapV3');
  });

  test('inReviewBand is false for clean data', () => {
    const report = screen(makeCleanData());
    expect(report.inReviewBand).toBe(false);
  });
});

// ─────────────────────────────────────────────────────────────────
// Hard-exclude rules — each produces FAIL with correct rule ID
// ─────────────────────────────────────────────────────────────────

describe('hard-exclude rules', () => {
  test('HX-001: riba lending → FAIL', () => {
    const report = screen(makeCleanData({ hasRibaLending: true }));
    expect(report.verdict).toBe('FAIL');
    expect(getRule(report, 'HX-001').verdict).toBe('FAIL');
  });

  test('HX-002: funding rate income → FAIL', () => {
    const report = screen(makeCleanData({ hasFundingRateIncome: true }));
    expect(report.verdict).toBe('FAIL');
    expect(getRule(report, 'HX-002').verdict).toBe('FAIL');
  });

  test('HX-003: front-running → FAIL', () => {
    const report = screen(makeCleanData({ hasFrontRunning: true }));
    expect(report.verdict).toBe('FAIL');
    expect(getRule(report, 'HX-003').verdict).toBe('FAIL');
  });

  test('HX-004: riba securities → FAIL', () => {
    const report = screen(makeCleanData({ hasRibaSecurities: true }));
    expect(report.verdict).toBe('FAIL');
    expect(getRule(report, 'HX-004').verdict).toBe('FAIL');
  });

  test('HX-005: maisir → FAIL', () => {
    const report = screen(makeCleanData({ hasMaisir: true }));
    expect(report.verdict).toBe('FAIL');
    expect(getRule(report, 'HX-005').verdict).toBe('FAIL');
  });

  test('multiple hard-excludes → FAIL (not just first)', () => {
    const report = screen(makeCleanData({ hasRibaLending: true, hasFrontRunning: true }));
    expect(report.verdict).toBe('FAIL');
    expect(getRule(report, 'HX-001').verdict).toBe('FAIL');
    expect(getRule(report, 'HX-003').verdict).toBe('FAIL');
  });
});

// ─────────────────────────────────────────────────────────────────
// RS-001: Debt-to-assets ratio
// ─────────────────────────────────────────────────────────────────

describe('RS-001: debt-to-assets', () => {
  test('0.32 → PASS', () => {
    const r = getRule(screen(makeCleanData({ debtToAssets: 0.32 })), 'RS-001');
    expect(r.verdict).toBe('PASS');
  });

  test('0.33 → FAIL (threshold is >=)', () => {
    const r = getRule(screen(makeCleanData({ debtToAssets: 0.33 })), 'RS-001');
    expect(r.verdict).toBe('FAIL');
  });

  test('0.50 → FAIL', () => {
    const r = getRule(screen(makeCleanData({ debtToAssets: 0.50 })), 'RS-001');
    expect(r.verdict).toBe('FAIL');
  });

  test('null → REVIEW', () => {
    const r = getRule(screen(makeCleanData({ debtToAssets: null })), 'RS-001');
    expect(r.verdict).toBe('REVIEW');
  });

  test('null debt with no other issues → overall REVIEW', () => {
    const report = screen(makeCleanData({ debtToAssets: null }));
    expect(report.verdict).toBe('REVIEW');
  });
});

// ─────────────────────────────────────────────────────────────────
// RS-002: Non-compliant revenue ratio — three-zone boundary
// ─────────────────────────────────────────────────────────────────

describe('RS-002: non-compliant revenue ratio (three-zone)', () => {
  test('0.0499 → PASS (just below review threshold)', () => {
    const r = getRule(screen(makeCleanData({ nonCompliantRevenueRatio: 0.0499 })), 'RS-002');
    expect(r.verdict).toBe('PASS');
  });

  test('0.05 exactly → REVIEW', () => {
    const r = getRule(screen(makeCleanData({ nonCompliantRevenueRatio: 0.05 })), 'RS-002');
    expect(r.verdict).toBe('REVIEW');
  });

  test('0.051 → FAIL', () => {
    const r = getRule(screen(makeCleanData({ nonCompliantRevenueRatio: 0.051 })), 'RS-002');
    expect(r.verdict).toBe('FAIL');
  });

  test('0.10 → FAIL', () => {
    const r = getRule(screen(makeCleanData({ nonCompliantRevenueRatio: 0.10 })), 'RS-002');
    expect(r.verdict).toBe('FAIL');
  });

  test('0.01 → PASS', () => {
    const r = getRule(screen(makeCleanData({ nonCompliantRevenueRatio: 0.01 })), 'RS-002');
    expect(r.verdict).toBe('PASS');
  });

  test('null → REVIEW', () => {
    const r = getRule(screen(makeCleanData({ nonCompliantRevenueRatio: null })), 'RS-002');
    expect(r.verdict).toBe('REVIEW');
  });

  test('inReviewBand true when 0.05 exactly', () => {
    const report = screen(makeCleanData({ nonCompliantRevenueRatio: 0.05 }));
    expect(report.inReviewBand).toBe(true);
  });

  test('inReviewBand false when 0.0499', () => {
    const report = screen(makeCleanData({ nonCompliantRevenueRatio: 0.0499 }));
    expect(report.inReviewBand).toBe(false);
  });

  test('inReviewBand false when 0.051 (FAIL band, not review band)', () => {
    const report = screen(makeCleanData({ nonCompliantRevenueRatio: 0.051 }));
    expect(report.inReviewBand).toBe(false);
  });
});

// ─────────────────────────────────────────────────────────────────
// RS-003: Interest-bearing assets ratio
// ─────────────────────────────────────────────────────────────────

describe('RS-003: interest-bearing assets ratio', () => {
  test('0.10 → PASS', () => {
    const r = getRule(screen(makeCleanData({ interestBearingAssetsRatio: 0.10 })), 'RS-003');
    expect(r.verdict).toBe('PASS');
  });

  test('0.33 → FAIL', () => {
    const r = getRule(screen(makeCleanData({ interestBearingAssetsRatio: 0.33 })), 'RS-003');
    expect(r.verdict).toBe('FAIL');
  });

  test('null → REVIEW', () => {
    const r = getRule(screen(makeCleanData({ interestBearingAssetsRatio: null })), 'RS-003');
    expect(r.verdict).toBe('REVIEW');
  });
});

// ─────────────────────────────────────────────────────────────────
// QS-001: Primary activity halal
// ─────────────────────────────────────────────────────────────────

describe('QS-001: primary activity', () => {
  test('halal=true → PASS', () => {
    const r = getRule(screen(makeCleanData({ primaryActivityIsHalal: true })), 'QS-001');
    expect(r.verdict).toBe('PASS');
  });

  test('halal=false → FAIL', () => {
    const r = getRule(screen(makeCleanData({ primaryActivityIsHalal: false })), 'QS-001');
    expect(r.verdict).toBe('FAIL');
  });
});

// ─────────────────────────────────────────────────────────────────
// QS-002: Gold exchange atomicity
// ─────────────────────────────────────────────────────────────────

describe('QS-002: gold exchange atomic', () => {
  test('null → PASS (not applicable)', () => {
    const r = getRule(screen(makeCleanData({ goldExchangeIsAtomic: null })), 'QS-002');
    expect(r.verdict).toBe('PASS');
  });

  test('true → PASS', () => {
    const r = getRule(screen(makeCleanData({ goldExchangeIsAtomic: true })), 'QS-002');
    expect(r.verdict).toBe('PASS');
  });

  test('false → FAIL', () => {
    const r = getRule(screen(makeCleanData({ goldExchangeIsAtomic: false })), 'QS-002');
    expect(r.verdict).toBe('FAIL');
  });
});

// ─────────────────────────────────────────────────────────────────
// QS-003: LP income swap-fee only
// ─────────────────────────────────────────────────────────────────

describe('QS-003: LP income', () => {
  test('null → PASS (not applicable)', () => {
    const r = getRule(screen(makeCleanData({ lpIncomeIsSwapFeeOnly: null })), 'QS-003');
    expect(r.verdict).toBe('PASS');
  });

  test('true → PASS', () => {
    const r = getRule(screen(makeCleanData({ lpIncomeIsSwapFeeOnly: true })), 'QS-003');
    expect(r.verdict).toBe('PASS');
  });

  test('false → REVIEW (not FAIL — advisory only)', () => {
    const r = getRule(screen(makeCleanData({ lpIncomeIsSwapFeeOnly: false })), 'QS-003');
    expect(r.verdict).toBe('REVIEW');
  });
});

// ─────────────────────────────────────────────────────────────────
// Verdict priority: FAIL > REVIEW > PASS
// ─────────────────────────────────────────────────────────────────

describe('verdict priority', () => {
  test('FAIL beats REVIEW', () => {
    const report = screen(makeCleanData({
      hasRibaLending: true,          // FAIL
      nonCompliantRevenueRatio: 0.05, // REVIEW
    }));
    expect(report.verdict).toBe('FAIL');
  });

  test('REVIEW beats PASS', () => {
    const report = screen(makeCleanData({
      debtToAssets: null,            // REVIEW
      nonCompliantRevenueRatio: 0.01, // PASS
    }));
    expect(report.verdict).toBe('REVIEW');
  });

  test('all missing ratios → REVIEW overall', () => {
    const report = screen(makeCleanData({
      debtToAssets:               null,
      nonCompliantRevenueRatio:   null,
      interestBearingAssetsRatio: null,
    }));
    expect(report.verdict).toBe('REVIEW');
  });
});

// ─────────────────────────────────────────────────────────────────
// Known protocol fixtures
// ─────────────────────────────────────────────────────────────────

describe('known protocol fixtures', () => {
  test('Aave V3 FAILS (HX-001)', () => {
    const report = screen({
      protocolName: 'aave-v3',
      debtToAssets: null,
      nonCompliantRevenueRatio: 1.0,
      interestBearingAssetsRatio: 1.0,
      hasRibaLending: true,
      hasFundingRateIncome: false,
      hasFrontRunning: false,
      hasRibaSecurities: false,
      hasMaisir: false,
      primaryActivityIsHalal: false,
      goldExchangeIsAtomic: null,
      lpIncomeIsSwapFeeOnly: null,
    });
    expect(report.verdict).toBe('FAIL');
    expect(getRule(report, 'HX-001').verdict).toBe('FAIL');
  });

  test('OUSG FAILS (HX-004)', () => {
    const report = screen({
      protocolName: 'ousg-ondo',
      debtToAssets: null,
      nonCompliantRevenueRatio: 1.0,
      interestBearingAssetsRatio: 1.0,
      hasRibaLending: false,
      hasFundingRateIncome: false,
      hasFrontRunning: false,
      hasRibaSecurities: true,
      hasMaisir: false,
      primaryActivityIsHalal: false,
      goldExchangeIsAtomic: null,
      lpIncomeIsSwapFeeOnly: null,
    });
    expect(report.verdict).toBe('FAIL');
    expect(getRule(report, 'HX-004').verdict).toBe('FAIL');
  });

  test('Uniswap V3 USDC/ETH PASSES', () => {
    const report = screen({
      protocolName: 'uniswap-v3-usdc-eth',
      debtToAssets: 0.0,
      nonCompliantRevenueRatio: 0.0,
      interestBearingAssetsRatio: 0.0,
      hasRibaLending: false,
      hasFundingRateIncome: false,
      hasFrontRunning: false,
      hasRibaSecurities: false,
      hasMaisir: false,
      primaryActivityIsHalal: true,
      goldExchangeIsAtomic: null,
      lpIncomeIsSwapFeeOnly: true,
    });
    expect(report.verdict).toBe('PASS');
  });

  test('GoldExchangeAdapter PAXG PASSES', () => {
    const report = screen({
      protocolName: 'gold-exchange-paxg',
      debtToAssets: 0.0,
      nonCompliantRevenueRatio: 0.0,
      interestBearingAssetsRatio: 0.0,
      hasRibaLending: false,
      hasFundingRateIncome: false,
      hasFrontRunning: false,
      hasRibaSecurities: false,
      hasMaisir: false,
      primaryActivityIsHalal: true,
      goldExchangeIsAtomic: true,
      lpIncomeIsSwapFeeOnly: null,
    });
    expect(report.verdict).toBe('PASS');
  });

  test('Hyperliquid ETH-PERP FAILS (HX-002 + HX-005)', () => {
    const report = screen({
      protocolName: 'hyperliquid-eth-perp',
      debtToAssets: null,
      nonCompliantRevenueRatio: 1.0,
      interestBearingAssetsRatio: null,
      hasRibaLending: false,
      hasFundingRateIncome: true,
      hasFrontRunning: false,
      hasRibaSecurities: false,
      hasMaisir: true,
      primaryActivityIsHalal: false,
      goldExchangeIsAtomic: null,
      lpIncomeIsSwapFeeOnly: null,
    });
    expect(report.verdict).toBe('FAIL');
    expect(getRule(report, 'HX-002').verdict).toBe('FAIL');
    expect(getRule(report, 'HX-005').verdict).toBe('FAIL');
  });
});

// ─────────────────────────────────────────────────────────────────
// Determinism: same input always produces same output
// ─────────────────────────────────────────────────────────────────

describe('determinism', () => {
  test('identical inputs produce identical outputs', () => {
    const data = makeCleanData({ nonCompliantRevenueRatio: 0.03 });
    const r1 = screen(data, 1000);
    const r2 = screen(data, 1000);
    expect(JSON.stringify(r1)).toBe(JSON.stringify(r2));
  });

  test('different timestamps do not change verdict', () => {
    const data = makeCleanData();
    const r1 = screen(data, 1000);
    const r2 = screen(data, 9999999);
    expect(r1.verdict).toBe(r2.verdict);
    expect(r1.results.map(r => r.verdict)).toEqual(r2.results.map(r => r.verdict));
  });
});
