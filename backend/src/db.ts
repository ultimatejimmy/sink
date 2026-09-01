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
          title TEXT,
          authors TEXT,
          book_key TEXT,
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

    // Ensure sync_key and progress metadata columns exist in existing deployments
    try {
      await db.prepare("ALTER TABLE users ADD COLUMN sync_key TEXT").run();
    } catch {}
    try {
      await db.prepare("ALTER TABLE progress ADD COLUMN title TEXT").run();
    } catch {}
    try {
      await db.prepare("ALTER TABLE progress ADD COLUMN authors TEXT").run();
    } catch {}
    try {
      await db.prepare("ALTER TABLE progress ADD COLUMN book_key TEXT").run();
    } catch {}
    try {
      await db.prepare("CREATE INDEX IF NOT EXISTS idx_progress_user_book ON progress(username, book_key)").run();
    } catch {}

    // Pre-link existing hashes for Career of Evil so all current devices sync immediately
    try {
      await db.prepare(`
        UPDATE progress
        SET book_key = 'career of evil::galbraith robert',
            title = 'Career of Evil',
            authors = 'Robert Galbraith'
        WHERE document_hash IN (
          'fa5747ab8e9e0eddb95d03626d6408cc',
          'ff33ab2520aab06b92ade64534d0dd01',
          '425c14bf3fff496a8824ddac52ebea9d',
          'd105732afe1ddbe069188c0eeab0f631',
          'b9923abdac3ea92459d5b15c93e694ca'
        ) AND (book_key IS NULL OR book_key = '')
      `).run();
    } catch {}

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
  documentHash: string,
  bookKey?: string | null,
  altHashes?: string[] | null
): Promise<ProgressRecord | null> {
  await ensureDatabase(db);

  // 1. Direct match on documentHash
  const exact = await db
    .prepare(
      "SELECT username, document_hash, percentage, progress, device, device_id, timestamp, title, authors, book_key FROM progress WHERE username = ? AND document_hash = ?"
    )
    .bind(username, documentHash)
    .first<ProgressRecord>();

  // 2. Check by bookKey: find the most recent reading progress across any device for this book
  const effectiveBookKey = bookKey || (exact && exact.book_key);
  if (effectiveBookKey) {
    const bestByBook = await db
      .prepare(
        "SELECT username, document_hash, percentage, progress, device, device_id, timestamp, title, authors, book_key FROM progress WHERE username = ? AND book_key = ? ORDER BY timestamp DESC LIMIT 1"
      )
      .bind(username, effectiveBookKey)
      .first<ProgressRecord>();

    if (bestByBook) {
      if (!exact || (bestByBook.timestamp > exact.timestamp && bestByBook.percentage > exact.percentage)) {
        return bestByBook;
      }
    }
  }

  // 3. Check altHashes if provided and exact wasn't found or is at beginning
  if (altHashes && altHashes.length > 0) {
    for (const altHash of altHashes) {
      if (altHash && altHash !== documentHash) {
        const alt = await db
          .prepare(
            "SELECT username, document_hash, percentage, progress, device, device_id, timestamp, title, authors, book_key FROM progress WHERE username = ? AND document_hash = ?"
          )
          .bind(username, altHash)
          .first<ProgressRecord>();
        if (alt && (!exact || alt.timestamp > exact.timestamp)) {
          return alt;
        }
      }
    }
  }

  return exact || null;
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
    title?: string | null;
    authors?: string | null;
    book_key?: string | null;
    alt_hashes?: string[] | null;
  }
): Promise<boolean> {
  await ensureDatabase(db);
  const query = `
    INSERT INTO progress (username, document_hash, percentage, progress, device, device_id, timestamp, title, authors, book_key)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(username, document_hash) DO UPDATE SET
      percentage = excluded.percentage,
      progress = excluded.progress,
      device = excluded.device,
      device_id = excluded.device_id,
      timestamp = excluded.timestamp,
      title = COALESCE(excluded.title, progress.title),
      authors = COALESCE(excluded.authors, progress.authors),
      book_key = COALESCE(excluded.book_key, progress.book_key)
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
      record.timestamp,
      record.title ?? null,
      record.authors ?? null,
      record.book_key ?? null
    )
    .run();

  // Also sync all alt_hashes if provided
  if (record.alt_hashes && Array.isArray(record.alt_hashes)) {
    for (const altHash of record.alt_hashes) {
      if (altHash && altHash !== record.document_hash) {
        try {
          await db
            .prepare(query)
            .bind(
              record.username,
              altHash,
              record.percentage,
              record.progress,
              record.device,
              record.device_id,
              record.timestamp,
              record.title ?? null,
              record.authors ?? null,
              record.book_key ?? null
            )
            .run();
        } catch {}
      }
    }
  }

  // If book_key is known, update all existing devices for this user with this book
  if (record.book_key) {
    try {
      await db
        .prepare(`
          UPDATE progress
          SET percentage = ?, progress = ?, device = ?, device_id = ?, timestamp = ?
          WHERE username = ? AND book_key = ? AND document_hash != ?
        `)
        .bind(
          record.percentage,
          record.progress,
          record.device,
          record.device_id,
          record.timestamp,
          record.username,
          record.book_key,
          record.document_hash
        )
        .run();
    } catch {}
  }

  return result.success;
}
