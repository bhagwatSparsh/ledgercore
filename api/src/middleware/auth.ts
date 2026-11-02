import { Request, Response, NextFunction } from "express";
import jwt from "jsonwebtoken";
import { SessionContext } from "../db/pool";

export interface AuthedRequest extends Request {
  session?: SessionContext;
}

interface TokenPayload {
  userId: string;
  role: "admin" | "customer" | "auditor";
}

/**
 * Verifies the Bearer JWT and attaches req.session, which every route
 * handler then passes straight into withSession() so Postgres RLS sees
 * the same identity the API layer just authenticated.
 */
export function requireAuth(req: AuthedRequest, res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing or malformed Authorization header." });
  }

  const token = header.slice("Bearer ".length);
  try {
    const payload = jwt.verify(token, process.env.JWT_SECRET as string) as TokenPayload;
    req.session = { userId: payload.userId, role: payload.role };
    next();
  } catch {
    return res.status(401).json({ error: "Invalid or expired token." });
  }
}

/** Route-level gate for admin-only endpoints (freeze accounts, view audit logs, etc). */
export function requireRole(...allowed: Array<"admin" | "customer" | "auditor">) {
  return (req: AuthedRequest, res: Response, next: NextFunction) => {
    if (!req.session || !allowed.includes(req.session.role)) {
      return res.status(403).json({ error: "Insufficient privileges for this action." });
    }
    next();
  };
}
