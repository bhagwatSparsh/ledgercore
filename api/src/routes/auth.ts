import { Router } from "express";
import bcrypt from "bcrypt";
import jwt from "jsonwebtoken";
import { z } from "zod";
import { pool, withSession } from "../db/pool";

const router = Router();

const registerSchema = z.object({
  fullName: z.string().min(2).max(150),
  email: z.string().email(),
  phone: z.string().min(7).max(20),
  password: z.string().min(8),
});

router.post("/register", async (req, res, next) => {
  try {
    const body = registerSchema.parse(req.body);
    const passwordHash = await bcrypt.hash(body.password, 12);

    // Registration happens before we have a user_id to set as the RLS
    // identity, so it must run with the 'admin' role context. This isn't
    // just about the INSERT itself (users_insert's WITH CHECK is simply
    // `true`) -- it's because INSERT ... RETURNING also evaluates the
    // table's SELECT policy on the row being handed back, and with no
    // current_user_id set, users_self_select would have nothing to match
    // against and silently block the RETURNING clause under RLS.
    const user = await withSession({ userId: null, role: "admin" }, async (client) => {
      const result = await client.query(
        `INSERT INTO users (full_name, email, phone, password_hash, kyc_status)
         VALUES ($1, $2, $3, $4, 'PENDING')
         RETURNING user_id, full_name, email, kyc_status`,
        [body.fullName, body.email, body.phone, passwordHash]
      );
      await client.query(
        `INSERT INTO user_roles (user_id, role_id) VALUES ($1, (SELECT role_id FROM roles WHERE role_name = 'customer'))`,
        [result.rows[0].user_id]
      );
      return result.rows[0];
    });

    const token = jwt.sign(
      { userId: user.user_id, role: "customer" },
      process.env.JWT_SECRET as string,
      { expiresIn: process.env.JWT_EXPIRES_IN as any }
    );

    res.status(201).json({ user, token });
  } catch (err) {
    next(err);
  }
});

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string(),
});

router.post("/login", async (req, res, next) => {
  try {
    const body = loginSchema.parse(req.body);

    // Login itself must run with elevated DB privileges (role: 'admin')
    // purely to bypass RLS and locate the user row by email -- we don't
    // yet know the user's own identity to set as the RLS context. This
    // is the one legitimate "pre-auth" query in the whole API.
    const row = await withSession({ userId: null, role: "admin" }, async (client) => {
      const result = await client.query(
        `SELECT u.user_id, u.password_hash, u.is_active,
                COALESCE(
                  (SELECT r.role_name FROM user_roles ur JOIN roles r ON r.role_id = ur.role_id
                   WHERE ur.user_id = u.user_id ORDER BY ur.role_id LIMIT 1),
                  'customer'
                ) AS role_name
         FROM users u WHERE u.email = $1`,
        [body.email]
      );
      return result.rows[0];
    });

    if (!row || !row.is_active) {
      return res.status(401).json({ error: "Invalid email or password." });
    }

    const valid = await bcrypt.compare(body.password, row.password_hash);
    if (!valid) {
      return res.status(401).json({ error: "Invalid email or password." });
    }

    const token = jwt.sign(
      { userId: row.user_id, role: row.role_name },
      process.env.JWT_SECRET as string,
      { expiresIn: process.env.JWT_EXPIRES_IN as any }
    );

    res.json({ token, role: row.role_name });
  } catch (err) {
    next(err);
  }
});

export default router;
