// ─────────────────────────────────────────────────────────────────────────────
// Module 2: Pool Stress
// Reads pool utilization from the protocol and classifies it by risk level.
// ─────────────────────────────────────────────────────────────────────────────

import { type Abi, encodeFunctionData, decodeFunctionResult } from "viem"
import { type EVMClient, type Runtime, encodeCallMsg, bytesToHex } from "@chainlink/cre-sdk"

import type { Config, PoolStats, RiskLevel } from "../types.js"
import { THRESHOLDS } from "../constants.js"
import { formatUtilization, calculateRiskLevel } from "../utils.js"

export function checkPoolStress(
  runtime: Runtime<Config>,
  evmClient: EVMClient,
  protocolAddress: string,
  protocolABI: Abi,
): { stats: PoolStats; poolHealthScore: number; riskLevel: RiskLevel } {
  // 1. Initiate EVM read — do NOT .result() yet
  const callData = encodeFunctionData({
    abi: protocolABI,
    functionName: "getPoolStats",
    args: [],
  })

  const readPromise = evmClient.callContract(runtime, {
    call: encodeCallMsg({
      from: "0x0000000000000000000000000000000000000000",
      to: protocolAddress as `0x${string}`,
      data: callData,
    }),
  })

  // 2. Resolve: (utilization bps, totalLiquidity, totalBorrowed)
  const reply = readPromise.result()
  const [utilizationBps, totalLiquidity, totalBorrowed] = decodeFunctionResult({
    abi: protocolABI,
    functionName: "getPoolStats",
    data: bytesToHex(reply.data),
  }) as unknown as [bigint, bigint, bigint]

  // 3. Normalise
  const utilization = formatUtilization(utilizationBps)

  // 4. Health score: inverse of utilization, 0–100
  const poolHealthScore = Math.round((1 - utilization) * 100)

  // 5. Risk level: "above" direction (higher util = higher risk)
  const riskLevel = calculateRiskLevel(utilization, THRESHOLDS.pool, "above")

  return {
    stats: { utilization, totalLiquidity, totalBorrowed },
    poolHealthScore,
    riskLevel,
  }
}
