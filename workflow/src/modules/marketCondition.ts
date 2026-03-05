// ─────────────────────────────────────────────────────────────────────────────
// Module 3: Market Condition
// CRITICAL — all HTTP calls MUST use NodeRuntime + consensusMedianAggregation.
// Never use Date.now() — only runtime.now().
// ─────────────────────────────────────────────────────────────────────────────

import { type Abi, encodeFunctionData, decodeFunctionResult } from "viem"
import {
  type Runtime,
  type NodeRuntime,
  type EVMClient,
  HTTPClient,
  consensusMedianAggregation,
  encodeCallMsg,
  bytesToHex,
} from "@chainlink/cre-sdk"

import type { Config, MarketData, MarketCondition } from "../types.js"
import {
  COINGECKO_ETH_URL,
  FEAR_GREED_URL,
  ETH_MOCK_ADDRESS,
  THRESHOLDS,
} from "../constants.js"

type PriceSnapshot = { price: bigint; timestamp: bigint }

export function checkMarketCondition(
  runtime: Runtime<Config>,
  evmClient: EVMClient,
  gatewayAddress: string,
  gatewayABI: Abi,
): MarketData {
  // ── STEP 1 — Initiate EVM read for on-chain snapshot (do NOT .result() yet) ──

  const snapshotCallData = encodeFunctionData({
    abi: gatewayABI,
    functionName: "lastPriceSnapshot",
    args: [ETH_MOCK_ADDRESS],
  })

  const snapshotRead = evmClient.callContract(runtime, {
    call: encodeCallMsg({
      from: "0x0000000000000000000000000000000000000000",
      to: gatewayAddress as `0x${string}`,
      data: snapshotCallData,
    }),
  })

  // ── STEP 2 — Initiate ETH price fetch via NodeRuntime ─────────────────────

  const ethPriceRun = runtime.runInNodeMode(
    (nodeRuntime: NodeRuntime<Config>): number => {
      const client = new HTTPClient()
      const res = client.sendRequest(nodeRuntime, {
        method: "GET",
        url: COINGECKO_ETH_URL,
        headers: { Accept: "application/json" },
      }).result()

      if (res.statusCode !== 200) {
        throw new Error(`CoinGecko error: ${res.statusCode}`)
      }

      const body = new TextDecoder().decode(res.body)
      const data = JSON.parse(body) as { ethereum: { usd: number } }

      // NORMALIZE before returning — critical for consensus across nodes
      return Math.round(data.ethereum.usd * 100) / 100
    },
    consensusMedianAggregation<number>(),
  )()

  // ── STEP 3 — Initiate Fear & Greed fetch via NodeRuntime ──────────────────

  const fearGreedRun = runtime.runInNodeMode(
    (nodeRuntime: NodeRuntime<Config>): number => {
      const client = new HTTPClient()
      const res = client.sendRequest(nodeRuntime, {
        method: "GET",
        url: FEAR_GREED_URL,
        headers: { Accept: "application/json" },
      }).result()

      if (res.statusCode !== 200) {
        throw new Error(`FearGreed error: ${res.statusCode}`)
      }

      const body = new TextDecoder().decode(res.body)
      const data = JSON.parse(body) as { data: Array<{ value: string }> }

      // Normalize: integer in [0, 100]
      return Math.round(Number(data.data[0]!.value))
    },
    consensusMedianAggregation<number>(),
  )()

  // ── STEP 4 — Resolve all (initiation complete above; now resolve in order) ─

  const snapshotReply = snapshotRead.result()
  const snapshot = decodeFunctionResult({
    abi: gatewayABI,
    functionName: "lastPriceSnapshot",
    data: bytesToHex(snapshotReply.data),
  }) as unknown as PriceSnapshot

  const currentPrice = ethPriceRun.result()
  const fearGreedIndex = fearGreedRun.result()

  // ── STEP 5 — Calculate hourly price change ────────────────────────────────

  let priceChange1h = 0
  if (snapshot.timestamp > 0n) {
    const storedPrice = Number(snapshot.price) / 100
    const timeDeltaMs =
      runtime.now().getTime() - Number(snapshot.timestamp) * 1000
    const rawChange = (currentPrice - storedPrice) / storedPrice
    // Annualise to 1-hour window
    priceChange1h = (rawChange / timeDeltaMs) * 3_600_000
  }

  // ── STEP 6 — Classify market condition ───────────────────────────────────

  let condition: MarketCondition = "CALM"
  if (priceChange1h <= THRESHOLDS.market.EXTREME) {
    condition = "EXTREME"
  } else if (priceChange1h <= THRESHOLDS.market.VOLATILE) {
    condition = "VOLATILE"
  }

  // ── STEP 7 — Return ───────────────────────────────────────────────────────

  return { currentPrice, fearGreedIndex, priceChange1h, condition }
}
