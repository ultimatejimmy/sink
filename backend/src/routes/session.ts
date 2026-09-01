import { Hono } from "hono";
import { Env, KosyncErrors } from "../types";
import { ensureDatabase, createUser, getUserByUsername, upsertUser } from "../db";
import { hashPassword } from "../auth";

export const sessionRouter = new Hono<{ Bindings: Env }>();

// In-memory fallback cache for sessions
const memorySessions = new Map<string, { status: string; username: string; userkey: string; expiresAt: number }>();

// Helper: Generate random 6-character uppercase alphanumeric code (omitting ambiguous characters 0, 1, I, O)
function generateSessionId(): string {
  const chars = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
  let result = "";
  const randomBytes = new Uint8Array(6);
  crypto.getRandomValues(randomBytes);
  for (let i = 0; i < 6; i++) {
    result += chars[randomBytes[i] % chars.length];
  }
  return result;
}

// Ensure session table exists in D1
async function ensureSessionTable(db: D1Database): Promise<void> {
  try {
    await db.exec(`
      CREATE TABLE IF NOT EXISTS pairing_sessions (
        session_id TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        username TEXT,
        userkey TEXT,
        expires_at INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      );
    `);
  } catch (err) {
    console.warn("Pairing session table init warning:", err);
  }
}

// 1. POST /api/session/create -> E-reader requests pairing code
sessionRouter.post("/create", async (c) => {
  const db = c.env.DB;
  const sessionId = generateSessionId();
  const now = Math.floor(Date.now() / 1000);
  const expiresAt = now + 600; // 10 minutes TTL

  memorySessions.set(sessionId, {
    status: "pending",
    username: "",
    userkey: "",
    expiresAt: expiresAt * 1000,
  });

  if (db) {
    try {
      await ensureSessionTable(db);
      await db
        .prepare(
          "INSERT INTO pairing_sessions (session_id, status, expires_at, created_at) VALUES (?, 'pending', ?, ?)"
        )
        .bind(sessionId, expiresAt, now)
        .run();
    } catch (err) {
      console.warn("Failed to persist session to D1, using memory store:", err);
    }
  }

  return c.json({
    success: true,
    session_id: sessionId,
    expires_in: 600,
  });
});

// 2. GET /api/session/:id/poll -> E-reader polls for confirmation
sessionRouter.get("/:id/poll", async (c) => {
  const sessionId = c.req.param("id").toUpperCase();
  const db = c.env.DB;
  const now = Math.floor(Date.now() / 1000);

  let session = memorySessions.get(sessionId);

  if ((!session || session.status !== "ready") && db) {
    try {
      await ensureSessionTable(db);
      const row = await db
        .prepare("SELECT status, username, userkey, expires_at FROM pairing_sessions WHERE session_id = ?")
        .bind(sessionId)
        .first<{ status: string; username: string; userkey: string; expires_at: number }>();

      if (row) {
        if (row.expires_at < now) {
          return c.json({ error: "Session expired" }, 404);
        }
        session = {
          status: row.status,
          username: row.username || "",
          userkey: row.userkey || "",
          expiresAt: row.expires_at * 1000,
        };
      }
    } catch (err) {
      console.warn("Error querying D1 session:", err);
    }
  }

  if (!session || session.expiresAt < Date.now()) {
    return c.json({ error: "Session expired or not found" }, 404);
  }

  if (session.status === "ready" && session.username && session.userkey) {
    const origin = new URL(c.req.url).origin;
    return c.json({
      success: true,
      status: "ready",
      username: session.username,
      userkey: session.userkey,
      server_url: origin,
    });
  }

  // Still waiting for phone/browser confirmation
  return c.body(null, 204);
});

// 3. POST /api/session/:id/submit -> Phone/PC browser confirms pairing
sessionRouter.post("/:id/submit", async (c) => {
  const sessionId = c.req.param("id").toUpperCase();
  const db = c.env.DB;
  const now = Math.floor(Date.now() / 1000);

  let session = memorySessions.get(sessionId);

  if ((!session || session.expiresAt < Date.now()) && db) {
    try {
      await ensureSessionTable(db);
      const row = await db
        .prepare("SELECT status, username, userkey, expires_at FROM pairing_sessions WHERE session_id = ?")
        .bind(sessionId)
        .first<{ status: string; username: string; userkey: string; expires_at: number }>();

      if (row && row.expires_at >= now) {
        session = {
          status: row.status,
          username: row.username || "",
          userkey: row.userkey || "",
          expiresAt: row.expires_at * 1000,
        };
      }
    } catch (err) {
      console.warn("Error querying D1 session:", err);
    }
  }

  if (!session || session.expiresAt < Date.now()) {
    return c.json(
      {
        success: false,
        error: "Pairing code not found or expired. Please check the code shown on your e-reader screen.",
      },
      404
    );
  }

  let body: { username?: string; userkey?: string };
  try {
    body = await c.req.json();
  } catch {
    body = {};
  }

  // If no username provided, use a default primary sync account
  const username = (body.username || "primary_reader").trim();
  let userkey = body.userkey ? body.userkey.trim() : "";

  // Ensure user account exists and has matching password hash in D1
  if (db) {
    try {
      await ensureDatabase(db);
      const existing = await getUserByUsername(db, username);
      if (existing) {
        if (existing.sync_key && (!body.userkey || body.userkey.startsWith("sync_key_"))) {
          // Stable multi-device key: reuse existing account key so all devices share authentication
          userkey = existing.sync_key;
        } else {
          if (!userkey) {
            userkey = `sink_key_${sessionId}`;
          }
          const hash = await hashPassword(userkey);
          await upsertUser(db, username, hash, userkey);
        }
      } else {
        // First device pairing: generate/use userkey and store as account's persistent sync_key
        if (!userkey) {
          userkey = `sink_key_${sessionId}`;
        }
        const hash = await hashPassword(userkey);
        await createUser(db, username, hash, userkey);
      }
    } catch (err) {
      console.error("Error creating/updating user during pairing:", err);
    }
  }

  if (!userkey) {
    userkey = `sink_key_${sessionId}`;
  }

  // Update session status
  memorySessions.set(sessionId, {
    status: "ready",
    username,
    userkey,
    expiresAt: Date.now() + 600000,
  });

  if (db) {
    try {
      await ensureSessionTable(db);
      await db
        .prepare(
          "UPDATE pairing_sessions SET status = 'ready', username = ?, userkey = ? WHERE session_id = ?"
        )
        .bind(username, userkey, sessionId)
        .run();
    } catch (err) {
      console.warn("Failed to update D1 session:", err);
    }
  }

  return c.json({
    success: true,
    message: "Device paired successfully! Your e-reader will automatically connect.",
  });
});
