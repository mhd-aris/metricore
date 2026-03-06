// ─────────────────────────────────────────────────────────────────────────────
// Metricore CRE Workflow — Main Orchestrator
// Runs every 5 minutes via CronTrigger.
// Reads protocol state → classifies risk → alerts → proposes on-chain action
// via KeystoneForwarder (writeReport → onReport pattern).
// ─────────────────────────────────────────────────────────────────────────────

import { encodeAbiParameters, encodeFunctionData } from "viem"
import {
  handler,
  EVMClient,
  CronCapability,
  Runner,
  type Runtime,
  encodeCallMsg,
  prepareReportRequest,
} from "@chainlink/cre-sdk"

import { checkPositionHealth } from "./modules/positionHealth.js"
import { checkPoolStress } from "./modules/poolStress.js"
import { checkMarketCondition } from "./modules/marketCondition.js"
import { classifyRisk, determineAction } from "./riskEngine.js"
import { sendAlert } from "./alerting.js"
import { ETH_MOCK_ADDRESS, ACTION_TYPES } from "./constants.js"
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

  // 2. Create EVMClient for Base Sepolia
  const evmClient = new EVMClient(
    EVMClient.SUPPORTED_CHAIN_SELECTORS["ethereum-testnet-sepolia-base-1"],
  )

  // 3. Run all three risk checks sequentially
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

  // 7. EVM write for HIGH/CRITICAL — submit action via KeystoneForwarder
  //    CRE write path: runtime.report() → evmClient.writeReport()
  //    → KeystoneForwarder → MetricoreGateway.onReport(metadata, report)
  //    Report payload: abi.encode(bytes32 actionType)
  if (action === "REDUCE_LEVERAGE" || action === "PAUSE_POSITIONS") {
    const actionType =
      action === "REDUCE_LEVERAGE"
        ? ACTION_TYPES.REDUCE_LEVERAGE
        : ACTION_TYPES.PAUSE_POSITIONS

    // Encode report payload: actionType as bytes32
    const reportPayload = encodeAbiParameters(
      [{ type: "bytes32" }],
      [actionType],
    ) as `0x${string}`

    console.log("[METRICORE] Attempting proposeAction via writeReport, actionType:", actionType)
    try {
      const reportRequest = prepareReportRequest(reportPayload)
      const signedReport = runtime.report(reportRequest).result()
      // WriteCreReportRequestJson: receiver is string, no $report marker
      evmClient.writeReport(runtime, {
        receiver: gatewayAddr,
        report: signedReport,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        gasConfig: { gasLimit: "1000000" } as any,
      }).result()
      console.log("[METRICORE] proposeAction SUCCESS")
    } catch (e) {
      console.error("[METRICORE] proposeAction FAILED:", e)
    }

    console.log(`[METRICORE] Proposed action: ${action}`)
  }

  // 8. ALWAYS update price snapshot at end of every run
  //    updatePriceSnapshot has no access control — callable by anyone
  const snapshotCallData = encodeFunctionData({
    abi: gatewayABI,
    functionName: "updatePriceSnapshot",
    args: [ETH_MOCK_ADDRESS, BigInt(Math.round(marketData.currentPrice * 100))],
  })

  try {
    evmClient.callContract(runtime, {
      call: encodeCallMsg({
        from: "0x0000000000000000000000000000000000000000",
        to: gatewayAddr as `0x${string}`,
        data: snapshotCallData,
      }),
    }).result()
  } catch (e) {
    console.error("[METRICORE] updatePriceSnapshot FAILED:", e)
  }

  console.log(`[METRICORE] Price snapshot updated: $${marketData.currentPrice}`)

  return {}
}
