// ─────────────────────────────────────────────────────────────────────────────
// Metricore CRE Workflow — Main Orchestrator
// Runs every 5 minutes via CronTrigger.
// Reads protocol state → classifies risk → alerts → proposes on-chain action.
// ─────────────────────────────────────────────────────────────────────────────

import { encodeFunctionData } from "viem"
import {
  handler,
  EVMClient,
  CronCapability,
  Runner,
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
import { abi as protocolABI } from "./abis/MockInvalendProtocol.js"
import { abi as gatewayABI } from "./abis/MetricoreGateway.js"

// ── Workflow initializer — returns handler array for Runner ───────────────────

function initWorkflow(config: Config) {
  const cronCap = new CronCapability()
  return [
    handler(
      cronCap.trigger({ schedule: config.schedule }),
      onRiskCheck,
    ),
  ]
}

// ── WASM entry point — required by CRE WASM compiler ─────────────────────────

export async function main() {
  const runner = await Runner.newRunner<Config>()
  await runner.run(initWorkflow)
}

main()

// ── Main workflow function ────────────────────────────────────────────────────

function onRiskCheck(runtime: Runtime<Config>): Record<string, never> {
  // 1. Load secrets
  const gatewayAddr = runtime.getSecret({ id: "GATEWAY_ADDRESS" }).result().value
  const protocolAddr = runtime.getSecret({ id: "PROTOCOL_ADDRESS" }).result().value
  const sentinelAddr = runtime.getSecret({ id: "SENTINEL_ADDRESS" }).result().value
  console.log("[METRICORE] sentinelAddr:", sentinelAddr)

  // 2. Create EVMClient for Base Sepolia
  const evmClient = new EVMClient(
    EVMClient.SUPPORTED_CHAIN_SELECTORS["ethereum-testnet-sepolia-base-1"],
  )

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

    console.log("[METRICORE] Attempting proposeAction from:", sentinelAddr)
    try {
      evmClient.callContract(runtime, {
        call: encodeCallMsg({
          from: sentinelAddr as `0x${string}`,
          to: gatewayAddr as `0x${string}`,
          data: writeCallData,
        }),
      }).result()
      console.log(`[METRICORE] proposeAction SUCCESS`)
    } catch (e) {
      console.error("[METRICORE] proposeAction FAILED:", e)
    }

    console.log(`[METRICORE] Proposed action: ${action}`)
  }

  // 8. ALWAYS update price snapshot at end of every run
  const snapshotCallData = encodeFunctionData({
    abi: gatewayABI,
    functionName: "updatePriceSnapshot",
    args: [ETH_MOCK_ADDRESS, BigInt(Math.round(marketData.currentPrice * 100))],
  })

  console.log("[METRICORE] Attempting updatePriceSnapshot from:", sentinelAddr)
  try {
    evmClient.callContract(runtime, {
      call: encodeCallMsg({
        from: sentinelAddr as `0x${string}`,
        to: gatewayAddr as `0x${string}`,
        data: snapshotCallData,
      }),
    }).result()
    console.log(`[METRICORE] updatePriceSnapshot SUCCESS`)
  } catch (e) {
    console.error("[METRICORE] updatePriceSnapshot FAILED:", e)
  }

  console.log(`[METRICORE] Price snapshot updated: $${marketData.currentPrice}`)

  return {}
}
