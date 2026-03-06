// ─────────────────────────────────────────────────────────────────────────────
// Shared TypeScript interfaces & enums for the Metricore CRE workflow.
// These mirror the on-chain structs and the CODING_CONTEXT.md schema.
// ─────────────────────────────────────────────────────────────────────────────

// ── CRE Workflow Config (mirrors workflow/config.json) ───────────────────────
// Non-sensitive config parsed from config.json at runtime.
// Secrets (ALERT_WEBHOOK_URL, GATEWAY_ADDRESS, PROTOCOL_ADDRESS) are accessed
// via runtime.getSecret({ id: "..." }) — NOT via runtime.config.

export type Config = {
  schedule: string        // e.g. "*/5 * * * *"
  chainName: string       // e.g. "ethereum-testnet-sepolia-base-1"
}

// ── Risk classification ───────────────────────────────────────────────────────

export type RiskLevel = "SAFE" | "ELEVATED" | "HIGH" | "CRITICAL"

export type MarketCondition = "CALM" | "VOLATILE" | "EXTREME"

// ── On-chain structs (mirroring MockInvalendProtocol.Position) ────────────────
// Field types match EVM ABI decoding conventions:
//   uint256 → bigint, address → string (0x-prefixed), bool → boolean

export interface Position {
  id: bigint
  trader: string
  collateralAmount: bigint
  prefundedAmount: bigint
  isActive: boolean
}

export interface PositionWithRisk extends Position {
  healthFactor: number  // normalised to [0, 1+] range: basisPoints / 10000
  riskLevel: RiskLevel
}

// ── Pool stats (getPoolStats return values) ───────────────────────────────────

export interface PoolStats {
  utilization: number      // normalised: basisPoints / 10000
  totalLiquidity: bigint   // USDC, 6 decimals
  totalBorrowed: bigint    // USDC, 6 decimals
}

// ── Price snapshot (lastPriceSnapshot mapping value) ─────────────────────────
// price: USD × 100 (e.g. 300000n = $3000.00)
// timestamp: block.timestamp (seconds since epoch)

export interface PriceSnapshot {
  price: bigint
  timestamp: bigint
}

// ── Market data (output of marketCondition module) ───────────────────────────

export interface MarketData {
  currentPrice: number     // USD (e.g. 3000.00) — normalised from CoinGecko
  fearGreedIndex: number   // 0–100
  priceChange1h: number    // fraction (e.g. -0.07 = -7%)
  condition: MarketCondition
}

// ── Risk report (output of riskEngine) ───────────────────────────────────────

export interface RiskReport {
  positionRisk: {
    positions: PositionWithRisk[]
    worstLevel: RiskLevel
  }
  poolRisk: {
    stats: PoolStats
    riskLevel: RiskLevel
  }
  marketRisk: MarketData
  combinedLevel: RiskLevel
  timestamp: number        // milliseconds since epoch (runtime.now().getTime())
}

// ── AlertPayload — sent from CRE workflow to POST /alert ─────────────────────
// Schema matches CODING_CONTEXT.md BAGIAN 3 exactly.

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
