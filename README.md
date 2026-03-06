# Metricore

> **Monitor everything. Trust nothing. Automate protection.**

A protocol-agnostic risk monitoring and adaptive safeguard system for under-collateralized DeFi lending protocols, built on **Chainlink CRE** (Compute Runtime Environment). Invalend Protocol is the first integration target.

---

## What is Metricore?

Metricore is a decentralized risk controller that runs as a **Chainlink CRE Workflow** — a tamper-resistant, BFT-consensus compute layer that continuously monitors on-chain lending positions and autonomously enforces risk thresholds without requiring human intervention.

Every 5 minutes, the workflow reads live position and pool data directly from Base Sepolia, fetches external market signals, classifies risk across three tiers, and — when thresholds are breached — proposes protective actions on-chain. A separate `MetricoreGateway` smart contract independently re-verifies the conditions before executing, making the system trustless end-to-end.

The core problem it solves: under-collateralized lending protocols (where borrowers lock only 20% collateral and the pool funds 80%) are highly sensitive to rapid market moves. Metricore provides the early-warning and circuit-breaker layer that prevents liquidation cascades before they happen.

---

## Architecture

```
[Cron Trigger — every 5 minutes]
         |
         v
[EVM Read] Active positions + health factors  (MockInvalendProtocol)
[EVM Read] Pool stats: utilization, liquidity  (MockInvalendProtocol)
[EVM Read] Last price snapshot                 (MetricoreGateway)
         |
         v
[HTTP — NodeRuntime] CoinGecko API → current ETH price
[HTTP — NodeRuntime] Alternative.me → Fear & Greed Index
         |
         v
[Risk Engine — Runtime]
  Module 1: Position Health Monitor   → health factor per trader
  Module 2: Pool Stress Indicator     → utilization + concentration risk
  Module 3: Market Condition          → price delta + sentiment score
         |
         v
[Three-Tier Response]
  ELEVATED  ──→  HTTP Alert to webhook
  HIGH      ──→  EVM Write: proposeAction(REDUCE_LEVERAGE)
  CRITICAL  ──→  EVM Write: proposeAction(PAUSE_POSITIONS)
         |
         v
[MetricoreGateway — Propose-Verify-Execute]
  1. Check cooldown (30 min per action type)
  2. Re-verify threshold independently from on-chain state
  3. Execute on MockInvalendProtocol if condition confirmed
```

---

## Three-Tier Response System

| Risk Level | Trigger Condition | Automated Action |
|---|---|---|
| **ELEVATED** | Health factor < 85% OR pool utilization > 80% | HTTP alert to webhook (Discord/Telegram) |
| **HIGH** | Health factor < 82% OR pool utilization > 85% | On-chain: `proposeAction(REDUCE_LEVERAGE)` |
| **CRITICAL** | Health factor < 80% OR market crash > 15% in 1h | On-chain: `proposeAction(PAUSE_POSITIONS)` |

The **Propose-Verify-Execute** pattern means the CRE Sentinel never has direct authority over the protocol. `MetricoreGateway` independently re-reads on-chain state and only executes if the threshold is genuinely met — making the system trustless without requiring governance overhead.

---

## Chainlink Integration

Every file that directly uses Chainlink CRE SDK or infrastructure:

| File | Chainlink Usage |
|---|---|
| [workflow/src/index.ts](workflow/src/index.ts) | `Runner.newRunner()`, `handler()`, `CronCapability`, `EVMClient.callContract()` for `proposeAction` + `updatePriceSnapshot` |
| [workflow/src/modules/positionHealth.ts](workflow/src/modules/positionHealth.ts) | `EVMClient.callContract()` via `encodeCallMsg` — reads position health factors |
| [workflow/src/modules/poolStress.ts](workflow/src/modules/poolStress.ts) | `EVMClient.callContract()` — reads pool utilization and liquidity stats |
| [workflow/src/modules/marketCondition.ts](workflow/src/modules/marketCondition.ts) | `HTTPClient` inside `NodeRuntime` + `consensusMedianAggregation` — fetches CoinGecko + Fear & Greed |
| [workflow/src/riskEngine.ts](workflow/src/riskEngine.ts) | Pure risk classification logic — consumed by `index.ts` for action determination |
| [workflow/src/alerting.ts](workflow/src/alerting.ts) | `HTTPClient` inside `NodeRuntime` + `consensusIdenticalAggregation` — fire-and-forget webhook |
| [workflow/workflow.yaml](workflow/workflow.yaml) | CRE workflow config — entry point, config path, secrets path |
| [project.yaml](project.yaml) | CRE project config — RPC endpoints for Base Sepolia |

---

## Live Contracts on Base Sepolia

| Contract | Address | Verified |
|---|---|---|
| MockInvalendProtocol | [`0x6912ded3394Af5B02edf63e4A05547d5d810C298`](https://sepolia.basescan.org/address/0x6912ded3394Af5B02edf63e4A05547d5d810C298) | ✅ Basescan |
| MetricoreGateway | [`0x462a32097a1A89b02fAD4AE0613852Cf0a3b198a`](https://sepolia.basescan.org/address/0x462a32097a1A89b02fAD4AE0613852Cf0a3b198a) | ✅ Basescan |

**Seeded State:**

| Position | Health Factor | Risk Level |
|---|---|---|
| 0 | 93.00% | SAFE |
| 1 | 94.00% | SAFE |
| 2 | 95.00% | SAFE |
| 3 | 84.00% | ELEVATED |
| 4 | 85.00% | ELEVATED |
| 5 | 86.00% | ELEVATED |
| 6 | 81.00% | HIGH |
| 7 | 79.00% | CRITICAL |

Pool utilization seeded at **65%** (normal), stress-injectable to **87%** (HIGH) via `InjectStress.s.sol`.

---

## Setup & Run

### 1. Contracts (already deployed — for reference)

```bash
cd contracts
forge install
forge test           # 19/19 tests pass
forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
forge script script/Seed.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast

# Optional: inject stress scenario for demo
forge script script/InjectStress.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### 2. Backend (webhook receiver)

```bash
cd backend
npm install
npm run dev          # Starts Express server on port 3001

# Endpoints:
# GET  /health       — health check
# POST /alert        — receives risk alerts from CRE workflow
# GET  /alerts       — alert history
```

### 3. CRE Workflow (simulate)

```bash
# Prerequisites: CRE CLI installed, bun installed
npm install -g @chainlink/cre-cli
bun x cre-setup      # one-time WASM plugin setup

cd workflow
bun install

# Set required environment variables (see .env.example):
# ALERT_WEBHOOK_URL, GATEWAY_ADDRESS, PROTOCOL_ADDRESS, CRE_ETH_PRIVATE_KEY

# Run simulation against live Base Sepolia contracts:
cd ..
cre workflow simulate ./workflow -e .env

# Expected output:
# [METRICORE] Position risk: CRITICAL (position 7 at 79% HF)
# [METRICORE] Pool stress: 65% utilization — SAFE
# [METRICORE] Market: CALM
# [METRICORE] Combined level: CRITICAL — proposing PAUSE_POSITIONS
```

**.env.example** — required variables:
```env
CRE_ETH_PRIVATE_KEY=<deployer_private_key>
CRE_TARGET=local-settings
ALERT_WEBHOOK_URL=http://localhost:3001/alert
GATEWAY_ADDRESS=0x462a32097a1A89b02fAD4AE0613852Cf0a3b198a
PROTOCOL_ADDRESS=0x6912ded3394Af5B02edf63e4A05547d5d810C298
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
```

---

## Video Demo

[LINK TBD]

The video demonstrates:
- Live contracts on Basescan (MockInvalendProtocol + MetricoreGateway)
- `cre workflow simulate` — normal scenario (SAFE positions, 65% utilization)
- Stress injection → re-simulation (CRITICAL detected, PAUSE_POSITIONS proposed)
- Backend receiving alert payloads
- On-chain `proposeAction` transaction with `ActionExecuted` event

---

## Tech Stack

| Layer | Technology |
|---|---|
| CRE Workflow | TypeScript — `@chainlink/cre-sdk` v1.1.3 |
| Blockchain | Base Sepolia (chain ID: 84532) |
| Smart Contracts | Solidity ^0.8.20 — Foundry + OpenZeppelin v5 |
| EVM Encoding | viem — `encodeFunctionData` / `decodeFunctionResult` |
| External API 1 | CoinGecko — ETH/USD price (free tier, no key) |
| External API 2 | Alternative.me — Fear & Greed Index (free, no key) |
| Contract Testing | Forge — 19/19 tests passing |
| Alerting Backend | Express.js (TypeScript) — webhook receiver on port 3001 |

---

## Roadmap

### Phase 1 — Hackathon MVP (current)
- CRE Workflow with Cron trigger → EVM Read → HTTP calls → EVM Write
- Mock contracts on Base Sepolia with seeded and injectable stress data
- Propose-Verify-Execute pattern with 30-minute cooldown anti-oscillation
- CLI simulation demo + on-chain proposeAction confirmed

### Phase 2 — Post-Hackathon Integration (Q3 2026)
- Replace mock contracts with Invalend production contracts
- Replace CoinGecko with Chainlink Price Feeds (already used by Invalend)
- Real-time monitoring dashboard for LP pool health visibility
- Stress testing with historical volatility replay data

### Phase 3 — Protocol-Agnostic Module (Q4 2026+)
- Abstract interface so Metricore plugs into any under-collateralized lending protocol
- Governance mechanism for parameter adjustment (thresholds, cooldowns, batch size)
- Economic feedback loop: dynamic borrow rate adjustments based on real-time risk score
- "Metricore as-a-Service" positioning for external protocol integrations

---

## Project Structure

```
metricore/
├── project.yaml                       ← CRE project config (RPC endpoints)
├── workflow/
│   ├── workflow.yaml                  ← CRE workflow config
│   ├── config.json                    ← Non-sensitive workflow config
│   └── src/
│       ├── index.ts                   ← Main CRE orchestrator (Runner + handler)
│       ├── types.ts                   ← Shared types
│       ├── constants.ts               ← Thresholds, addresses, batch size
│       ├── utils.ts                   ← Risk classification helpers
│       ├── riskEngine.ts              ← On-chain action proposal
│       ├── alerting.ts                ← Webhook alert sender
│       ├── modules/
│       │   ├── positionHealth.ts      ← Module 1: per-position health factors
│       │   ├── poolStress.ts          ← Module 2: pool utilization monitoring
│       │   └── marketCondition.ts     ← Module 3: price delta + sentiment
│       └── abis/
│           ├── MockInvalendProtocol.ts
│           └── MetricoreGateway.ts
├── contracts/
│   ├── src/
│   │   ├── MockInvalendProtocol.sol   ← Mock DeFi lending protocol
│   │   └── MetricoreGateway.sol       ← Propose-Verify-Execute gateway
│   ├── test/                          ← 19/19 forge tests
│   └── script/
│       ├── Deploy.s.sol
│       ├── Seed.s.sol
│       └── InjectStress.s.sol
└── backend/
    └── src/
        ├── index.ts                   ← Express server
        └── routes/
            ├── alert.ts               ← POST /alert
            ├── health.ts              ← GET /health
            └── history.ts             ← GET /alerts
```

---

*Built for the Chainlink CRE Hackathon — Convergence, Track: Risk & Compliance.*
