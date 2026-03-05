// ─────────────────────────────────────────────────────────────────────────────
// Metricore CRE workflow constants.
// Thresholds mirror CODING_CONTEXT.md BAGIAN 4 — do NOT change values.
// ─────────────────────────────────────────────────────────────────────────────

// ── Risk thresholds ───────────────────────────────────────────────────────────

export const THRESHOLDS = {
  position: {
    ELEVATED: 0.85,   // healthFactor < 0.85
    HIGH: 0.82,       // healthFactor < 0.82
    CRITICAL: 0.80,   // healthFactor < 0.80
  },
  pool: {
    ELEVATED: 0.80,   // utilization > 80%
    HIGH: 0.85,       // utilization > 85%
    CRITICAL: 0.90,   // utilization > 90%
  },
  market: {
    VOLATILE: -0.05,  // price drop > 5% in 1 hour
    EXTREME: -0.15,   // price drop > 15% in 1 hour
  },
} as const

// ── Pagination ────────────────────────────────────────────────────────────────

export const BATCH_SIZE = 50

// ── Chain & contract constants ────────────────────────────────────────────────

export const BASE_SEPOLIA_CHAIN_ID = 84532

// WETH on Base — used as the ETH price oracle asset key
export const ETH_MOCK_ADDRESS = "0x4200000000000000000000000000000000000006"

// ── External API URLs ─────────────────────────────────────────────────────────

export const COINGECKO_ETH_URL =
  "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd"

export const FEAR_GREED_URL = "https://api.alternative.me/fng/?limit=1"

// ── Action type identifiers (keccak256 — must match MetricoreGateway.sol) ─────

export const ACTION_TYPES = {
  REDUCE_LEVERAGE:
    "0xd490a29c3eef0ab146e48c53e346c3115536112e333fab711e86c347c4f5a439" as `0x${string}`,
  PAUSE_POSITIONS:
    "0x8e6c1f8d118e3b2b2134314d9109d09eac06816d1e60cdf6ff3ace2b9b35ce6a" as `0x${string}`,
} as const
