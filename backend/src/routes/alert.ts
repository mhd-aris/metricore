import { Router } from "express"
import type { Request, Response } from "express"
import { validateAlert } from "../middleware/validation"
import { addAlert } from "../store/alertStore"
import type { AlertPayload, AlertResponse } from "../types"

// ─────────────────────────────────────────────────────────────────────────────
// ANSI color codes
// ─────────────────────────────────────────────────────────────────────────────

const RESET   = "\x1b[0m"
const YELLOW  = "\x1b[33m"
const BOLD    = "\x1b[1m"
const RED     = "\x1b[31m"

function colorForLevel(level: AlertPayload["level"]): string {
  switch (level) {
    case "ELEVATED": return YELLOW
    case "HIGH":     return BOLD + YELLOW
    case "CRITICAL": return BOLD + RED
  }
}

function formatTimestamp(ts: number): string {
  return new Date(ts).toISOString().replace("T", " ").slice(0, 19)
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /alert
// ─────────────────────────────────────────────────────────────────────────────

export const alertRouter = Router()

alertRouter.post("/", validateAlert, (req: Request, res: Response) => {
  const payload = req.body as AlertPayload

  const stored = addAlert(payload)

  const color = colorForLevel(payload.level)
  const ts    = formatTimestamp(payload.timestamp)

  console.log(
    `${color}[METRICORE ALERT] ${ts} | ${payload.level} | ${payload.message}${RESET}`
  )

  const response: AlertResponse = {
    received: true,
    alertId:  stored.alertId,
    timestamp: Date.now(),
  }

  res.status(200).json(response)
})
