import { User, ProgressRecord } from "./types";

let isInitialized = false;

/**
 * Self-bootstraps D1 schema on first run with zero manual SQL commands needed.
 * Uses db.batch() with prepared statements for 100% reliability across D1 runtimes.
 */
export async function ensureDatabase(db: D1Database): Promise<void> {
  if (!db) {
    throw new Error("D1 database binding 'DB' is not configured in Worker environment.");
  }
  if (isInitialized) return;

  try {
    await db.batch([
      db.prepare(`
        CREATE TABLE IF NOT EXISTS users (
          username TEXT PRIMARY KEY,
          password_hash TEXT NOT NULL,
          sync_key TEXT,
          created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
      `),
      db.prepare(`
        CREATE TABLE IF NOT EXISTS progress (
          username TEXT NOT NULL,
          document_hash TEXT NOT NULL,
          percentage REAL NOT NULL,
          progress TEXT NOT NULL,
          device TEXT NOT NULL,
          device_id TEXT,
          timestamp INTEGER NOT NULL,
          PRIMARY KEY (username, document_hash),
          FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE
        )
      `),
      db.prepare(`
        CREATE TABLE IF NOT EXISTS pairing_sessions (
          session_id TEXT PRIMARY KEY,
          status TEXT NOT NULL,
          username TEXT,
          userkey TEXT,
          expires_at INTEGER NOT NULL,
          created_at INTEGER NOT NULL
        )
      `),
      db.prepare(`
        CREATE INDEX IF NOT EXISTS idx_progress_username ON progress(username)
      `),
    ]);

    // Ensure sync_key column exists in existing deployments
    try {
      await db.prepare("ALTER TABLE users ADD COLUMN sync_key TEXT").run();
    } catch {
      // Column already exists or table freshly created
    }

    isInitialized = true;
  } catch (err) {
    console.error("Database batch bootstrap error:", err);
    throw err;
  }
}

export async function getUserByUsername(
  db: D1Database,
  username: string
): Promise<User | null> {
  await ensureDatabase(db);
  const result = await db
    .prepare("SELECT username, password_hash, sync_key, created_at FROM users WHERE username = ?")
    .bind(username)
    .first<User>();

  return result || null;
}

export async function createUser(
  db: D1Database,
  username: string,
  passwordHash: string,
  syncKey?: string
): Promise<boolean> {
  await ensureDatabase(db);
  const result = await db
    .prepare("INSERT INTO users (username, password_hash, sync_key) VALUES (?, ?, ?)")
    .bind(username, passwordHash, syncKey ?? null)
    .run();

  return result.success;
}

export async function upsertUser(
  db: D1Database,
  username: string,
  passwordHash: string,
  syncKey?: string
): Promise<boolean> {
  await ensureDatabase(db);
  const result = await db
    .prepare(`
      INSERT INTO users (username, password_hash, sync_key) VALUES (?, ?, ?)
      ON CONFLICT(username) DO UPDATE SET
        password_hash = excluded.password_hash,
        sync_key = COALESCE(excluded.sync_key, users.sync_key)
    `)
    .bind(username, passwordHash, syncKey ?? null)
    .run();

  return result.success;
}

export async function getProgress(
  db: D1Database,
  username: string,
  documentHash: string
): Promise<ProgressRecord | null> {
  await ensureDatabase(db);
  const result = await db
    .prepare(
      "SELECT username, document_hash, percentage, progress, device, device_id, timestamp FROM progress WHERE username = ? AND document_hash = ?"
    )
    .bind(username, documentHash)
    .first<ProgressRecord>();

  return result || null;
}

export async function upsertProgress(
  db: D1Database,
  record: {
    username: string;
    document_hash: string;
    percentage: number;
    progress: string;
    device: string;
    device_id: string | null;
    timestamp: number;
  }
): Promise<boolean> {
  await ensureDatabase(db);
  const query = `
    INSERT INTO progress (username, document_hash, percentage, progress, device, device_id, timestamp)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(username, document_hash) DO UPDATE SET
      percentage = excluded.percentage,
      progress = excluded.progress,
      device = excluded.device,
      device_id = excluded.device_id,
      timestamp = excluded.timestamp
  `;

  const result = await db
    .prepare(query)
    .bind(
      record.username,
      record.document_hash,
      record.percentage,
      record.progress,
      record.device,
      record.device_id,
      record.timestamp
    )
    .run();

  return result.success;
}
