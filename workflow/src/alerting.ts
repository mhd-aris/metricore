// ─────────────────────────────────────────────────────────────────────────────
// Alerting — HTTP POST to webhook via NodeRuntime.
// All HTTP calls MUST be inside NodeRuntime block.
// Never use Date.now() — only runtime.now().
// ─────────────────────────────────────────────────────────────────────────────

import {
  type Runtime,
  type NodeRuntime,
  HTTPClient,
  consensusIdenticalAggregation,
} from "@chainlink/cre-sdk"

import type { Config, RiskReport, AlertPayload } from "./types.js"
import { THRESHOLDS } from "./constants.js"

export function sendAlert(
  runtime: Runtime<Config>,
  report: RiskReport,
  action: "ALERT_ONLY" | "REDUCE_LEVERAGE" | "PAUSE_POSITIONS",
): void {
  // 1. Resolve webhook URL from secrets
  const webhookUrl = runtime.getSecret({ id: "ALERT_WEBHOOK_URL" }).result().value

  // 2. Build AlertPayload (schema from CODING_CONTEXT.md BAGIAN 3)
  const worstPosition = report.positionRisk.positions[0]
  const currentValue =
    worstPosition !== undefined
      ? worstPosition.healthFactor
      : report.poolRisk.stats.utilization

  const threshold =
    worstPosition !== undefined
      ? THRESHOLDS.position.CRITICAL
      : THRESHOLDS.pool.ELEVATED

  const triggerCondition =
    worstPosition !== undefined
      ? `Position ${worstPosition.trader} health factor ${(worstPosition.healthFactor * 100).toFixed(1)}%`
      : `Pool utilization ${(report.poolRisk.stats.utilization * 100).toFixed(1)}%`

  const payload: AlertPayload = {
    timestamp: runtime.now().getTime(),
    level: report.combinedLevel as "ELEVATED" | "HIGH" | "CRITICAL",
    module: "COMBINED",
    message: `[Metricore] Risk level ${report.combinedLevel} — ${triggerCondition}`,
    details: {
      triggerCondition,
      affectedPositions:
        report.positionRisk.positions
          .filter((p) => p.riskLevel !== "SAFE")
          .map((p) => p.trader),
      currentValue,
      threshold,
      marketCondition: report.marketRisk.condition,
    },
    ...(action !== "ALERT_ONLY" && {
      proposedAction: {
        type: action as "REDUCE_LEVERAGE" | "PAUSE_POSITIONS",
      },
    }),
  }

  // 3. HTTP POST via NodeRuntime — fire-and-forget majority
  const alertRun = runtime.runInNodeMode(
    (nodeRuntime: NodeRuntime<Config>): boolean => {
      try {
        const client = new HTTPClient()
        const res = client.sendRequest(nodeRuntime, {
          method: "POST",
          url: webhookUrl,
          headers: { "Content-Type": "application/json" },
          // RequestJson.body is base64-encoded bytes (protobuf JSON format)
          body: btoa(JSON.stringify(payload)),
        }).result()
        return res.statusCode === 200
      } catch (e) {
        // Log but always return true so consensus succeeds (fire-and-forget)
        console.error("[METRICORE] Alert HTTP error:", e)
        return true
      }
    },
    // All nodes return true (fire-and-forget) → identical aggregation trivially passes
    consensusIdenticalAggregation<boolean>(),
  )()

  // 4. Fire-and-forget: resolve but never let it crash the workflow
  try {
    alertRun.result()
  } catch (e) {
    console.error("[METRICORE] Alert send failed:", e)
  }
}
