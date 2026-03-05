// ─────────────────────────────────────────────────────────────────────────────
// Metricore CRE Workflow — Main Orchestrator
// Runs every 5 minutes via CronTrigger.
// Reads protocol state → classifies risk → alerts → proposes on-chain action.
// ─────────────────────────────────────────────────────────────────────────────

import { type Abi, encodeFunctionData } from "viem"
import {
  handler,
  EVMClient,
  CronCapability,
  type Runtime,
  encodeCallMsg,
} from "@chainlink/cre-sdk"

import { checkPositionHealth } from "./modules/positionHealth.js"
import { checkPoolStress } from "./modules/poolStress.js"
import { checkMarketCondition } from "./modules/marketCondition.js"
import { classifyRisk, determineAction } from "./riskEngine.js"
import { sendAlert } from "./alerting.js"
import { ETH_MOCK_ADDRESS, ACTION_TYPES } from "./constants.js"
import { encodeReduceLeverage, encodePausePositions } from "./utils.js"
import type { Config } from "./types.js"

// ── Placeholder ABIs — replace with JSON imports after `forge build` ──────────
// workflow/src/abis/ will be populated by copying contracts/out/ artifacts.

const protocolABI: Abi = []
const gatewayABI: Abi = []

// ── EVMClient: Base Sepolia chain selector ────────────────────────────────────

const BASE_SEPOLIA_SELECTOR =
  EVMClient.SUPPORTED_CHAIN_SELECTORS["ethereum-testnet-sepolia-base-1"]

// ── Handler registration ──────────────────────────────────────────────────────

handler(
  new CronCapability().trigger({ schedule: "*/5 * * * *" }),
  onRiskCheck,
)

// ── Main workflow function ────────────────────────────────────────────────────

function onRiskCheck(runtime: Runtime<Config>): Record<string, never> {
  // 1. Load secrets
  const gatewayAddr = runtime.getSecret({ id: "GATEWAY_ADDRESS" }).result().value
  const protocolAddr = runtime.getSecret({ id: "PROTOCOL_ADDRESS" }).result().value

  // 2. Create EVMClient for Base Sepolia
  const evmClient = new EVMClient(BASE_SEPOLIA_SELECTOR)

  // 3. Run all three risk checks sequentially
  //    (checkMarketCondition internally initiates NodeRuntime fetches before resolving)
  const positionResult = checkPositionHealth(runtime, evmClient, protocolAddr, protocolABI)
  const poolResult = checkPoolStress(runtime, evmClient, protocolAddr, protocolABI)
  const marketData = checkMarketCondition(runtime, evmClient, gatewayAddr, gatewayABI)

  // 4. Classify combined risk
  const report = classifyRisk(
    positionResult,
    poolResult,
    marketData,
    runtime.now().getTime(),
  )
  const action = determineAction(report)

  // 5. Log current status
  console.log(
    `[METRICORE] ${runtime.now().toISOString()} | Risk: ${report.combinedLevel}` +
      ` | Pool: ${(report.poolRisk.stats.utilization * 100).toFixed(1)}%` +
      ` | Market: ${marketData.condition}`,
  )

  // 6. Send alert for anything above SAFE
  if (action !== null) {
    sendAlert(runtime, report, action)
  } else {
    console.log("[METRICORE] All systems nominal. No action required.")
  }

  // 7. EVM write for HIGH/CRITICAL — propose action on Gateway
  if (action === "REDUCE_LEVERAGE" || action === "PAUSE_POSITIONS") {
    const actionType =
      action === "REDUCE_LEVERAGE"
        ? ACTION_TYPES.REDUCE_LEVERAGE
        : ACTION_TYPES.PAUSE_POSITIONS

    const actionData =
      action === "REDUCE_LEVERAGE"
        ? encodeReduceLeverage(3)
        : encodePausePositions()

    const writeCallData = encodeFunctionData({
      abi: gatewayABI,
      functionName: "proposeAction",
      args: [actionType, actionData],
    })

    evmClient.callContract(runtime, {
      call: encodeCallMsg({
        from: "0x0000000000000000000000000000000000000000",
        to: gatewayAddr as `0x${string}`,
        data: writeCallData,
      }),
    }).result()

    console.log(`[METRICORE] Proposed action: ${action}`)
  }

  // 8. ALWAYS update price snapshot at end of every run
  const snapshotCallData = encodeFunctionData({
    abi: gatewayABI,
    functionName: "updatePriceSnapshot",
    args: [ETH_MOCK_ADDRESS, BigInt(Math.round(marketData.currentPrice * 100))],
  })

  evmClient.callContract(runtime, {
    call: encodeCallMsg({
      from: "0x0000000000000000000000000000000000000000",
      to: gatewayAddr as `0x${string}`,
      data: snapshotCallData,
    }),
  }).result()

  console.log(`[METRICORE] Price snapshot updated: $${marketData.currentPrice}`)

  return {}
}
