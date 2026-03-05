import type { Request, Response, NextFunction } from "express"
import type { AlertPayload } from "../types"

const VALID_LEVELS = new Set(["ELEVATED", "HIGH", "CRITICAL"])

export function validateAlert(
  req: Request,
  res: Response,
  next: NextFunction
): void {
  const body = req.body as Partial<AlertPayload>

  if (typeof body.timestamp !== "number") {
    res.status(400).json({ error: "timestamp is required and must be a number" })
    return
  }

  if (!body.level || !VALID_LEVELS.has(body.level)) {
    res
      .status(400)
      .json({ error: "level must be one of: ELEVATED, HIGH, CRITICAL" })
    return
  }

  if (!body.details || typeof body.details !== "object") {
    res.status(400).json({ error: "details is required and must be an object" })
    return
  }

  if (typeof body.details.currentValue !== "number") {
    res
      .status(400)
      .json({ error: "details.currentValue is required and must be a number" })
    return
  }

  if (typeof body.details.threshold !== "number") {
    res
      .status(400)
      .json({ error: "details.threshold is required and must be a number" })
    return
  }

  next()
}
