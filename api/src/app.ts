import express from "express";
import helmet from "helmet";
import cors from "cors";
import rateLimit from "express-rate-limit";
import dotenv from "dotenv";

import authRoutes from "./routes/auth";
import accountRoutes from "./routes/accounts";
import transferRoutes from "./routes/transfers";
import beneficiaryRoutes from "./routes/beneficiaries";
import adminRoutes from "./routes/admin";
import { errorHandler } from "./middleware/errorHandler";

dotenv.config();

const app = express();

app.use(helmet());
app.use(cors());
app.use(express.json({ limit: "100kb" }));

// Global rate limiting. Transfer endpoints get a tighter limit applied
// in addition to this (see routes/transfers.ts mounting below), since
// that's the path most worth protecting from abuse.
const globalLimiter = rateLimit({
  windowMs: Number(process.env.RATE_LIMIT_WINDOW_MS ?? 60_000),
  max: Number(process.env.RATE_LIMIT_MAX ?? 100),
  standardHeaders: true,
  legacyHeaders: false,
});
app.use(globalLimiter);

app.get("/health", (_req, res) => res.json({ status: "ok", time: new Date().toISOString() }));

app.use("/auth", authRoutes);
app.use("/accounts", accountRoutes);
app.use("/transfers", transferRoutes);
app.use("/beneficiaries", beneficiaryRoutes);
app.use("/admin", adminRoutes);

app.use((req, res) => res.status(404).json({ error: "Not found." }));
app.use(errorHandler);

export default app;
