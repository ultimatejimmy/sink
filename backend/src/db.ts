import { User, ProgressRecord } from "./types";

export async function getUserByUsername(
  db: D1Database,
  username: string
): Promise<User | null> {
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
