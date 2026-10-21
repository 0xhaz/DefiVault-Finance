/**
 * SC Malaysia Shariah Screening Engine
 *
 * Pure and deterministic — no network calls, no side effects, no imports
 * from outside this file except the types file.
 *
 * Input:  ProtocolData  (financial metrics + qualitative flags)
 * Output: ScreeningReport (per-rule results, overall verdict, rule version)
 *
 * Verdict priority: FAIL > REVIEW > PASS
 *   - Any single FAIL → overall verdict is FAIL
 *   - Any REVIEW (and no FAIL) → overall verdict is REVIEW
 *   - All PASS → overall verdict is PASS
 *
 * Missing data: ratio screens with missing numerator or denominator → REVIEW.
 * Hard-exclude rules with missing data → PASS (cannot assert a violation).
 *
 * Authority: Securities Commission Malaysia (SC) SAC Revised Methodology (2013/2023)
 */

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

export type RuleVerdict = 'PASS' | 'REVIEW' | 'FAIL';

export interface RuleResult {
  ruleId:      string;
  category:    'HARD_EXCLUDE' | 'RATIO' | 'QUALITATIVE';
  description: string;
  verdict:     RuleVerdict;
  detail:      string;
  /** Present for RATIO rules — the computed metric value, or null if missing. */
  metricValue: number | null;
  threshold:   number | null;
}

export interface ScreeningReport {
  /** Rule file version this report was produced against. */
  ruleVersion:  string;
  timestamp:    number;           // Unix seconds
  protocolName: string;
  verdict:      RuleVerdict;
  results:      RuleResult[];
  /** Human-readable summary of the verdict. */
  summary:      string;
  /** Advisory note — always present. */
  disclaimer:   string;
  /**
   * Advisory flag: true when ANY result has metricValue between
   * RS-002 reviewThreshold and failThreshold (the "REVIEW band").
   */
  inReviewBand: boolean;
}

/**
 * Financial and qualitative data about a protocol to screen.
 * All numeric fields are ratios in [0, 1] unless noted.
 * null = missing / unavailable (triggers REVIEW on ratio screens).
 */
export interface ProtocolData {
  protocolName: string;

  // ── Ratio screens ──────────────────────────────────────────────
  /** RS-001: totalDebt / totalAssets. null → REVIEW. */
  debtToAssets: number | null;
  /** RS-002: nonCompliantRevenue / totalRevenue. null → REVIEW. */
  nonCompliantRevenueRatio: number | null;
  /** RS-003: interestBearingAssets / totalAssets. null → REVIEW. */
  interestBearingAssetsRatio: number | null;

  // ── Hard-exclude activity flags ────────────────────────────────
  /** HX-001: true if protocol engages in conventional interest-bearing lending. */
  hasRibaLending:        boolean;
  /** HX-002: true if protocol earns perpetual-derivative funding rates. */
  hasFundingRateIncome:  boolean;
  /** HX-003: true if strategy exploits bridge/order-flow front-running. */
  hasFrontRunning:       boolean;
  /** HX-004: true if protocol holds or distributes riba-based securities. */
  hasRibaSecurities:     boolean;
  /** HX-005: true if protocol engages in maisir (gambling/undelivered speculation). */
  hasMaisir:             boolean;

  // ── Qualitative flags ──────────────────────────────────────────
  /** QS-001: true if primary business activity is halal. */
  primaryActivityIsHalal:  boolean;
  /** QS-002: true if all gold/commodity exchanges are atomic (yad bi yad). */
  goldExchangeIsAtomic:    boolean | null;  // null → not applicable
  /** QS-003: true if LP income comes from swap fees only (not lending). */
  lpIncomeIsSwapFeeOnly:   boolean | null;  // null → not applicable
}

// ─────────────────────────────────────────────────────────────────────────────
// Hard-coded rule constants (mirrors shariah-rules.yaml)
// ─────────────────────────────────────────────────────────────────────────────

const RULE_VERSION = '1.0.0';

const DISCLAIMER =
  'This output is advisory only and does not constitute a Shariah board pronouncement. ' +
  'A qualified Shariah advisor must review any instrument before deployment. ' +
  'SC Malaysia SAC methodology applied; results may differ under other methodologies.';

// RS-002 has a three-zone boundary: < 0.05 → PASS, == 0.05 → REVIEW, > 0.05 → FAIL
const RS002_REVIEW_THRESHOLD = 0.05;
const RS002_FAIL_THRESHOLD   = 0.051;

// RS-001 and RS-003 share the same boundary: < 0.33 → PASS, >= 0.33 → FAIL
const RS001_RS003_THRESHOLD = 0.33;

// ─────────────────────────────────────────────────────────────────────────────
// Pure verdict combiner
// ─────────────────────────────────────────────────────────────────────────────

function combineVerdicts(verdicts: RuleVerdict[]): RuleVerdict {
  if (verdicts.includes('FAIL'))   return 'FAIL';
  if (verdicts.includes('REVIEW')) return 'REVIEW';
  return 'PASS';
}

// ─────────────────────────────────────────────────────────────────────────────
// Individual rule evaluators (all pure)
// ─────────────────────────────────────────────────────────────────────────────

function evalHX001(data: ProtocolData): RuleResult {
  const verdict: RuleVerdict = data.hasRibaLending ? 'FAIL' : 'PASS';
  return {
    ruleId:      'HX-001',
    category:    'HARD_EXCLUDE',
    description: 'Conventional interest-bearing lending or borrowing (riba)',
    verdict,
    detail:      data.hasRibaLending
      ? 'Protocol confirmed to engage in interest-bearing lending (riba). Hard exclude.'
      : 'No riba lending activity detected.',
    metricValue: null,
    threshold:   null,
  };
}

function evalHX002(data: ProtocolData): RuleResult {
  const verdict: RuleVerdict = data.hasFundingRateIncome ? 'FAIL' : 'PASS';
  return {
    ruleId:      'HX-002',
    category:    'HARD_EXCLUDE',
    description: 'Perpetual funding rate arbitrage (riba al-jahiliyyah analog)',
    verdict,
    detail:      data.hasFundingRateIncome
      ? 'Protocol earns funding rate income from perpetual derivatives. Hard exclude.'
      : 'No perpetual funding rate income detected.',
    metricValue: null,
    threshold:   null,
  };
}

function evalHX003(data: ProtocolData): RuleResult {
  const verdict: RuleVerdict = data.hasFrontRunning ? 'FAIL' : 'PASS';
  return {
    ruleId:      'HX-003',
    category:    'HARD_EXCLUDE',
    description: 'Front-running / information-asymmetry exploitation (gharar + zulm)',
    verdict,
    detail:      data.hasFrontRunning
      ? 'Strategy exploits information asymmetry (front-running). Hard exclude.'
      : 'No front-running activity detected.',
    metricValue: null,
    threshold:   null,
  };
}

function evalHX004(data: ProtocolData): RuleResult {
  const verdict: RuleVerdict = data.hasRibaSecurities ? 'FAIL' : 'PASS';
  return {
    ruleId:      'HX-004',
    category:    'HARD_EXCLUDE',
    description: 'Securities backed primarily by riba-based instruments',
    verdict,
    detail:      data.hasRibaSecurities
      ? 'Protocol holds or distributes riba-based securities (e.g. T-bill tokens). Hard exclude. See SR-001.'
      : 'No riba-based securities detected.',
    metricValue: null,
    threshold:   null,
  };
}

function evalHX005(data: ProtocolData): RuleResult {
  const verdict: RuleVerdict = data.hasMaisir ? 'FAIL' : 'PASS';
  return {
    ruleId:      'HX-005',
    category:    'HARD_EXCLUDE',
    description: 'Gambling, speculative derivatives with no underlying asset transfer (maisir)',
    verdict,
    detail:      data.hasMaisir
      ? 'Protocol engages in gambling or undelivered speculative derivatives. Hard exclude.'
      : 'No maisir activity detected.',
    metricValue: null,
    threshold:   null,
  };
}

function evalRS001(data: ProtocolData): RuleResult {
  const v = data.debtToAssets;
  if (v === null) {
    return {
      ruleId: 'RS-001', category: 'RATIO',
      description: 'Debt-to-total-assets ratio',
      verdict: 'REVIEW',
      detail: 'Debt-to-assets ratio unavailable. Missing data → REVIEW (cannot confirm compliance).',
      metricValue: null, threshold: RS001_RS003_THRESHOLD,
    };
  }
  const verdict: RuleVerdict = v >= RS001_RS003_THRESHOLD ? 'FAIL' : 'PASS';
  return {
    ruleId: 'RS-001', category: 'RATIO',
    description: 'Debt-to-total-assets ratio',
    verdict,
    detail: `debtToAssets = ${(v * 100).toFixed(2)}% (threshold < 33%). ${verdict === 'FAIL' ? 'Exceeds benchmark.' : 'Within benchmark.'}`,
    metricValue: v, threshold: RS001_RS003_THRESHOLD,
  };
}

function evalRS002(data: ProtocolData): RuleResult {
  const v = data.nonCompliantRevenueRatio;
  if (v === null) {
    return {
      ruleId: 'RS-002', category: 'RATIO',
      description: 'Non-compliant revenue ratio',
      verdict: 'REVIEW',
      detail: 'Non-compliant revenue ratio unavailable. Missing data → REVIEW.',
      metricValue: null, threshold: RS002_REVIEW_THRESHOLD,
    };
  }

  // Three-zone: < 0.05 → PASS, exactly 0.05 → REVIEW, > 0.05 (>= 0.051 in integer terms) → FAIL
  // Continuous: use exact float comparison (0.0499 → PASS, 0.05 → REVIEW, 0.051 → FAIL)
  let verdict: RuleVerdict;
  if (v >= RS002_FAIL_THRESHOLD) {
    verdict = 'FAIL';
  } else if (v >= RS002_REVIEW_THRESHOLD) {
    verdict = 'REVIEW';
  } else {
    verdict = 'PASS';
  }

  return {
    ruleId: 'RS-002', category: 'RATIO',
    description: 'Non-compliant revenue ratio',
    verdict,
    detail: `nonCompliantRevenueRatio = ${(v * 100).toFixed(3)}% (PASS < 5%, REVIEW = 5%, FAIL > 5.1%). Result: ${verdict}.`,
    metricValue: v, threshold: RS002_REVIEW_THRESHOLD,
  };
}

function evalRS003(data: ProtocolData): RuleResult {
  const v = data.interestBearingAssetsRatio;
  if (v === null) {
    return {
      ruleId: 'RS-003', category: 'RATIO',
      description: 'Interest-bearing deposits or securities ratio',
      verdict: 'REVIEW',
      detail: 'Interest-bearing asset ratio unavailable. Missing data → REVIEW.',
      metricValue: null, threshold: RS001_RS003_THRESHOLD,
    };
  }
  const verdict: RuleVerdict = v >= RS001_RS003_THRESHOLD ? 'FAIL' : 'PASS';
  return {
    ruleId: 'RS-003', category: 'RATIO',
    description: 'Interest-bearing deposits or securities ratio',
    verdict,
    detail: `interestBearingAssetsRatio = ${(v * 100).toFixed(2)}% (threshold < 33%). ${verdict === 'FAIL' ? 'Exceeds benchmark.' : 'Within benchmark.'}`,
    metricValue: v, threshold: RS001_RS003_THRESHOLD,
  };
}

function evalQS001(data: ProtocolData): RuleResult {
  const verdict: RuleVerdict = data.primaryActivityIsHalal ? 'PASS' : 'FAIL';
  return {
    ruleId: 'QS-001', category: 'QUALITATIVE',
    description: 'Core business must be halal',
    verdict,
    detail: data.primaryActivityIsHalal
      ? 'Primary business activity assessed as halal.'
      : 'Primary business activity assessed as non-halal. FAIL.',
    metricValue: null, threshold: null,
  };
}

function evalQS002(data: ProtocolData): RuleResult {
  if (data.goldExchangeIsAtomic === null) {
    return {
      ruleId: 'QS-002', category: 'QUALITATIVE',
      description: 'Gold and commodity exchanges must be atomic (yad bi yad)',
      verdict: 'PASS',
      detail: 'Not applicable — no gold/commodity exchange in this protocol.',
      metricValue: null, threshold: null,
    };
  }
  const verdict: RuleVerdict = data.goldExchangeIsAtomic ? 'PASS' : 'FAIL';
  return {
    ruleId: 'QS-002', category: 'QUALITATIVE',
    description: 'Gold and commodity exchanges must be atomic (yad bi yad)',
    verdict,
    detail: data.goldExchangeIsAtomic
      ? 'Gold exchanges confirmed atomic (single transaction). Yad bi yad satisfied. See SR-005.'
      : 'Gold exchanges are non-atomic (cross-chain or deferred). Fails yad bi yad requirement.',
    metricValue: null, threshold: null,
  };
}

function evalQS003(data: ProtocolData): RuleResult {
  if (data.lpIncomeIsSwapFeeOnly === null) {
    return {
      ruleId: 'QS-003', category: 'QUALITATIVE',
      description: 'LP fee income must come from genuine trade activity only (musharakah)',
      verdict: 'PASS',
      detail: 'Not applicable — no LP position in this protocol.',
      metricValue: null, threshold: null,
    };
  }
  const verdict: RuleVerdict = data.lpIncomeIsSwapFeeOnly ? 'PASS' : 'REVIEW';
  return {
    ruleId: 'QS-003', category: 'QUALITATIVE',
    description: 'LP fee income must come from genuine trade activity only (musharakah)',
    verdict,
    detail: data.lpIncomeIsSwapFeeOnly
      ? 'LP income sourced from swap fees only. Musharakah basis confirmed.'
      : 'LP income source unclear — may include lending yield. REVIEW required.',
    metricValue: null, threshold: null,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Main screening function (pure, deterministic, no side effects)
// ─────────────────────────────────────────────────────────────────────────────

export function screen(data: ProtocolData, timestampSeconds?: number): ScreeningReport {
  const results: RuleResult[] = [
    evalHX001(data),
    evalHX002(data),
    evalHX003(data),
    evalHX004(data),
    evalHX005(data),
    evalRS001(data),
    evalRS002(data),
    evalRS003(data),
    evalQS001(data),
    evalQS002(data),
    evalQS003(data),
  ];

  const verdict = combineVerdicts(results.map(r => r.verdict));

  // Check RS-002 review band
  const rs002 = results.find(r => r.ruleId === 'RS-002');
  const inReviewBand =
    rs002?.metricValue !== null &&
    rs002?.metricValue !== undefined &&
    rs002.metricValue >= RS002_REVIEW_THRESHOLD &&
    rs002.metricValue < RS002_FAIL_THRESHOLD;

  const summaryMap: Record<RuleVerdict, string> = {
    PASS:   `${data.protocolName} passes all SC Malaysia Shariah screening checks.`,
    REVIEW: `${data.protocolName} requires board review — one or more checks returned REVIEW. No FAIL detected.`,
    FAIL:   `${data.protocolName} fails SC Malaysia Shariah screening. One or more hard-exclude rules triggered. Not eligible for Shariah vault deployment without board override.`,
  };

  return {
    ruleVersion:  RULE_VERSION,
    timestamp:    timestampSeconds ?? Math.floor(Date.now() / 1000),
    protocolName: data.protocolName,
    verdict,
    results,
    summary:      summaryMap[verdict],
    disclaimer:   DISCLAIMER,
    inReviewBand,
  };
}
