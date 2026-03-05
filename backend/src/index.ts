import express from "express"
import cors from "cors"
import { alertRouter } from "./routes/alert"
import { healthRouter } from "./routes/health"
import { historyRouter } from "./routes/history"

const app  = express()
const PORT = process.env["PORT"] ?? "3001"

// ── Middleware ────────────────────────────────────────────────────────────────

app.use(cors())
app.use(express.json())

// ── Routes ───────────────────────────────────────────────────────────────────

app.use("/alert",  alertRouter)
app.use("/health", healthRouter)
app.use("/alerts", historyRouter)

// ── Global error handler ─────────────────────────────────────────────────────

app.use((err: Error, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  console.error("[ERROR]", err.message)
  res.status(500).json({ error: err.message })
})

// ── Start ─────────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`Metricore Webhook Server running on port ${PORT}`)
})

export default app
