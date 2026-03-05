// ─────────────────────────────────────────────────────────────────────────────
// Module 1: Position Health
// Reads active positions from the protocol and classifies each by risk level.
// ─────────────────────────────────────────────────────────────────────────────

import { type Abi, encodeFunctionData, decodeFunctionResult } from "viem"
import { type EVMClient, type Runtime, encodeCallMsg, bytesToHex } from "@chainlink/cre-sdk"

import type { Config, PositionWithRisk, RiskLevel } from "../types.js"
import { BATCH_SIZE, THRESHOLDS } from "../constants.js"
import { formatHealthFactor, calculateRiskLevel, combineRiskLevels } from "../utils.js"

type RawPosition = {
  id: bigint
  trader: string
  collateralAmount: bigint
  prefundedAmount: bigint
  isActive: boolean
}

export function checkPositionHealth(
  runtime: Runtime<Config>,
  evmClient: EVMClient,
  protocolAddress: string,
  protocolABI: Abi,
): { positions: PositionWithRisk[]; worstLevel: RiskLevel } {
  // 1. Initiate EVM read — do NOT .result() yet
  const callData = encodeFunctionData({
    abi: protocolABI,
    functionName: "getActivePositions",
    args: [BigInt(0), BigInt(BATCH_SIZE)],
  })

  const readPromise = evmClient.callContract(runtime, {
    call: encodeCallMsg({
      from: "0x0000000000000000000000000000000000000000",
      to: protocolAddress as `0x${string}`,
      data: callData,
    }),
  })

  // 2. Resolve
  const reply = readPromise.result()
  const decoded = decodeFunctionResult({
    abi: protocolABI,
    functionName: "getActivePositions",
    data: bytesToHex(reply.data),
  }) as unknown as [RawPosition[], bigint]

  const [rawPositions] = decoded

  // 3. Handle empty
  if (rawPositions.length === 0) {
    return { positions: [], worstLevel: "SAFE" }
  }

  // 4. Map: compute health factor inline (mirrors on-chain formula)
  const positions: PositionWithRisk[] = rawPositions.map((p) => {
    const hfBps = BigInt(
      Math.round(
        (Number(p.collateralAmount) * 10000) /
          ((Number(p.prefundedAmount) * 8000) / 10000),
      ),
    )
    const healthFactor = formatHealthFactor(hfBps)
    const riskLevel = calculateRiskLevel(healthFactor, THRESHOLDS.position, "below")

    return {
      id: p.id,
      trader: p.trader,
      collateralAmount: p.collateralAmount,
      prefundedAmount: p.prefundedAmount,
      isActive: p.isActive,
      healthFactor,
      riskLevel,
    }
  })

  // 5. Sort ascending by healthFactor (determinism — worst first)
  positions.sort((a, b) => a.healthFactor - b.healthFactor)

  // 6. Combine
  const worstLevel = combineRiskLevels(positions.map((p) => p.riskLevel))

  return { positions, worstLevel }
}
