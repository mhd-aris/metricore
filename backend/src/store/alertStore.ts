import { randomUUID } from "crypto"
import type { AlertPayload, StoredAlert } from "../types"

// ─────────────────────────────────────────────────────────────────────────────
// In-memory circular buffer — max 100 entries, newest first on read.
// Acceptable for hackathon; no persistence across restarts.
// ─────────────────────────────────────────────────────────────────────────────

const MAX_ENTRIES = 100

const alerts: StoredAlert[] = []

export function addAlert(payload: AlertPayload): StoredAlert {
  const stored: StoredAlert = {
    ...payload,
    alertId: randomUUID(),
    receivedAt: Date.now(),
  }

  alerts.unshift(stored) // newest first

  // Trim to max capacity
  if (alerts.length > MAX_ENTRIES) {
    alerts.splice(MAX_ENTRIES)
  }

  return stored
}

export function getAlerts(): StoredAlert[] {
  return [...alerts]
}

export function getCount(): number {
  return alerts.length
}

export function clearAlerts(): void {
  alerts.splice(0)
}
