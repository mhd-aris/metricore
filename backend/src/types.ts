// ─────────────────────────────────────────────────────────────────────────────
// AlertPayload — sent from CRE workflow to POST /alert
// Schema matches CODING_CONTEXT.md BAGIAN 3
// ─────────────────────────────────────────────────────────────────────────────

export interface AlertPayload {
  timestamp: number
  level: "ELEVATED" | "HIGH" | "CRITICAL"
  module: "POSITION_HEALTH" | "POOL_STRESS" | "MARKET_CONDITION" | "COMBINED"
  message: string
  details: {
    triggerCondition: string
    affectedPositions?: string[]
    currentValue: number
    threshold: number
    marketCondition?: "CALM" | "VOLATILE" | "EXTREME"
  }
  proposedAction?: {
    type: "REDUCE_LEVERAGE" | "PAUSE_POSITIONS"
    txHash?: string
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AlertResponse — returned from POST /alert
// ─────────────────────────────────────────────────────────────────────────────

export interface AlertResponse {
  received: boolean
  alertId: string
  timestamp: number
}

// ─────────────────────────────────────────────────────────────────────────────
// StoredAlert — AlertPayload enriched with server-assigned metadata
// ─────────────────────────────────────────────────────────────────────────────

export interface StoredAlert extends AlertPayload {
  alertId: string
  receivedAt: number
}
