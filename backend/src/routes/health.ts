import { Router } from "express"
import type { Request, Response } from "express"
import { getCount } from "../store/alertStore"

export const healthRouter = Router()

healthRouter.get("/", (_req: Request, res: Response) => {
  res.status(200).json({
    status:     "ok",
    uptime:     process.uptime(),
    alertCount: getCount(),
  })
})
