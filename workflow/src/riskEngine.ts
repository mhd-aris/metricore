// ─────────────────────────────────────────────────────────────────────────────
// Risk Engine — pure classification & action-determination logic.
// No SDK imports, no I/O. Fully deterministic.
// ─────────────────────────────────────────────────────────────────────────────

import type {
  PositionWithRisk,
  PoolStats,
  MarketData,
  RiskReport,
  RiskLevel,
} from "./types.js"
import { combineRiskLevels } from "./utils.js"

// ── classifyRisk ──────────────────────────────────────────────────────────────

export function classifyRisk(
  positionResult: { positions: PositionWithRisk[]; worstLevel: RiskLevel },
  poolResult: { stats: PoolStats; poolHealthScore: number; riskLevel: RiskLevel },
  marketData: MarketData,
  timestamp: number,
): RiskReport {
  // CALM → SAFE, VOLATILE → ELEVATED, EXTREME → HIGH
  const marketLevel: RiskLevel =
    marketData.condition === "EXTREME"
      ? "HIGH"
      : marketData.condition === "VOLATILE"
        ? "ELEVATED"
        : "SAFE"

  const combinedLevel = combineRiskLevels([
    positionResult.worstLevel,
    poolResult.riskLevel,
    marketLevel,
  ])

  return {
    positionRisk: {
      positions: positionResult.positions,
      worstLevel: positionResult.worstLevel,
    },
    poolRisk: {
      stats: poolResult.stats,
      riskLevel: poolResult.riskLevel,
    },
    marketRisk: marketData,
    combinedLevel,
    timestamp,
  }
}

// ── determineAction ───────────────────────────────────────────────────────────

export function determineAction(
  report: RiskReport,
): "ALERT_ONLY" | "REDUCE_LEVERAGE" | "PAUSE_POSITIONS" | null {
  switch (report.combinedLevel) {
    case "SAFE":
      return null
    case "ELEVATED":
      return "ALERT_ONLY"
    case "HIGH":
      return "REDUCE_LEVERAGE"
    case "CRITICAL":
      return "PAUSE_POSITIONS"
  }
}
