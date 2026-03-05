// ─────────────────────────────────────────────────────────────────────────────
// Pure utility functions for the Metricore CRE workflow.
// No Date.now(), no Math.random(), no async/await — deterministic only.
// ─────────────────────────────────────────────────────────────────────────────

import type { RiskLevel } from "./types.js"
import { THRESHOLDS } from "./constants.js"

// ── Normalisation helpers ─────────────────────────────────────────────────────

/**
 * Convert basis-point health factor (e.g. 9300n) to a normalised ratio (0.93).
 * On-chain formula: collateral * 10000 / (prefunded * 8000 / 10000)
 */
export function formatHealthFactor(basisPoints: bigint): number {
  return Number(basisPoints) / 10_000
}

/**
 * Convert basis-point utilization (e.g. 8500n) to a normalised ratio (0.85).
 * On-chain formula: totalBorrowed * 10000 / totalLiquidity
 */
export function formatUtilization(basisPoints: bigint): number {
  return Number(basisPoints) / 10_000
}

// ── Risk classification ───────────────────────────────────────────────────────

type PositionThresholds = typeof THRESHOLDS.position
type PoolThresholds = typeof THRESHOLDS.pool

/**
 * Classify a numeric value against a threshold set.
 *
 * @param value      - normalised value (e.g. 0.83 healthFactor)
 * @param thresholds - the matching THRESHOLDS sub-object
 * @param direction  - "below" → trigger when value < threshold (position health)
 *                     "above" → trigger when value > threshold (pool utilization)
 */
export function calculateRiskLevel(
  value: number,
  thresholds: PositionThresholds | PoolThresholds,
  direction: "below" | "above",
): RiskLevel {
  if (direction === "below") {
    // Position health — lower healthFactor = higher risk
    const t = thresholds as PositionThresholds
    if (value < t.CRITICAL) return "CRITICAL"
    if (value < t.HIGH)     return "HIGH"
    if (value < t.ELEVATED) return "ELEVATED"
    return "SAFE"
  } else {
    // Pool utilization — higher utilization = higher risk
    const t = thresholds as PoolThresholds
    if (value > t.CRITICAL) return "CRITICAL"
    if (value > t.HIGH)     return "HIGH"
    if (value > t.ELEVATED) return "ELEVATED"
    return "SAFE"
  }
}

// ── Risk level aggregation ────────────────────────────────────────────────────

const RISK_ORDER: Record<RiskLevel, number> = {
  SAFE: 0,
  ELEVATED: 1,
  HIGH: 2,
  CRITICAL: 3,
}

/**
 * Return the worst (highest) risk level from an array.
 * Empty array returns "SAFE".
 */
export function combineRiskLevels(levels: RiskLevel[]): RiskLevel {
  if (levels.length === 0) return "SAFE"
  return levels.reduce((worst, current) =>
    RISK_ORDER[current] > RISK_ORDER[worst] ? current : worst,
  )
}

// ── ABI encoding ──────────────────────────────────────────────────────────────

/**
 * ABI-encode a uint256 tier value for reduceMaxLeverage(uint256).
 * No external deps — manual left-padded hex encoding.
 */
export function encodeReduceLeverage(newTier: number): `0x${string}` {
  return `0x${BigInt(newTier).toString(16).padStart(64, "0")}` as `0x${string}`
}

/**
 * pauseNewPositions() takes no arguments → empty calldata.
 */
export function encodePausePositions(): `0x${string}` {
  return "0x"
}
