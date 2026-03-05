import { Router } from "express"
import type { Request, Response } from "express"
import { getAlerts } from "../store/alertStore"
import type { AlertPayload } from "../types"

export const historyRouter = Router()

historyRouter.get("/", (req: Request, res: Response) => {
  let alerts = getAlerts()

  // Optional filter: ?level=HIGH
  const level = req.query["level"] as AlertPayload["level"] | undefined
  if (level) {
    alerts = alerts.filter((a) => a.level === level)
  }

  res.status(200).json({
    alerts,
    total: alerts.length,
  })
})
