import { User, ProgressRecord } from "./types";

let isInitialized = false;

/**
 * Self-bootstraps D1 schema on first run with zero manual SQL commands needed.
 */
export async function ensureDatabase(db: D1Database): Promise<void> {
  if (isInitialized) return;
  try {
    await db.exec(`
      CREATE TABLE IF NOT EXISTS users (
        username TEXT PRIMARY KEY,
        password_hash TEXT NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );

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
      );

      CREATE INDEX IF NOT EXISTS idx_progress_username ON progress(username);
    `);
    isInitialized = true;
  } catch (err) {
    console.warn("Database initialization check warning:", err);
  }
}

export async function getUserByUsername(
  db: D1Database,
  username: string
): Promise<User | null> {
  await ensureDatabase(db);
  const result = await db
    .prepare("SELECT username, password_hash, created_at FROM users WHERE username = ?")
    .bind(username)
    .first<User>();

  return result || null;
}

export async function createUser(
  db: D1Database,
  username: string,
  passwordHash: string
): Promise<boolean> {
  await ensureDatabase(db);
  const result = await db
    .prepare("INSERT INTO users (username, password_hash) VALUES (?, ?)")
    .bind(username, passwordHash)
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
