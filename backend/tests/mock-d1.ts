import { User, ProgressRecord } from "../src/types";

/**
 * Pure JavaScript In-Memory Mock for Cloudflare D1Database.
 * Requires zero native binary dependencies.
 */
export function createMockD1(): D1Database {
  const usersTable = new Map<string, User>();
  const progressTable = new Map<string, ProgressRecord>();

  const createMeta = (changes: number): any => ({
    changes,
    duration: 0,
    rows_read: 0,
    rows_written: changes,
    last_row_id: 1,
    size_after: 0,
    changed_db: changes > 0,
  });

  const mockD1: Partial<D1Database> = {
    prepare(query: string) {
      let boundParams: any[] = [];

      const stmtObj: any = {
        bind(...values: any[]) {
          boundParams = values;
          return stmtObj;
        },

        async first<T = unknown>(colName?: string): Promise<T | null> {
          const q = query.trim();

          // User query: SELECT ... FROM users WHERE username = ?
          if (q.includes("FROM users WHERE username = ?")) {
            const username = boundParams[0];
            const user = usersTable.get(username) || null;
            if (!user) return null;
            if (colName) return (user as any)[colName] as T;
            return user as unknown as T;
          }

          // Progress query: SELECT ... FROM progress WHERE username = ? AND document_hash = ?
          if (q.includes("FROM progress WHERE username = ? AND document_hash = ?")) {
            const username = boundParams[0];
            const docHash = boundParams[1];
            const key = `${username}:${docHash}`;
            const prog = progressTable.get(key) || null;
            if (!prog) return null;
            if (colName) return (prog as any)[colName] as T;
            return prog as unknown as T;
          }

          // Progress by book_key query: SELECT ... FROM progress WHERE username = ? AND book_key = ?
          if (q.includes("FROM progress WHERE username = ? AND book_key = ?")) {
            const username = boundParams[0];
            const bookKey = boundParams[1];
            let best: ProgressRecord | null = null;
            for (const record of progressTable.values()) {
              if (record.username === username && record.book_key === bookKey) {
                if (!best || record.timestamp > best.timestamp) {
                  best = record;
                }
              }
            }
            if (!best) return null;
            if (colName) return (best as any)[colName] as T;
            return best as unknown as T;
          }

          return null;
        },

        async all<T = unknown>(): Promise<D1Result<T>> {
          return {
            results: [] as T[],
            success: true,
            meta: createMeta(0),
          };
        },

        async run<T = Record<string, unknown>>(): Promise<D1Result<T>> {
          const q = query.trim();

          // User insert / upsert: INSERT INTO users ...
          if (q.includes("INSERT INTO users")) {
            const username = boundParams[0];
            const passwordHash = boundParams[1];
            const syncKey = boundParams[2];
            const existing = usersTable.get(username);
            usersTable.set(username, {
              username,
              password_hash: passwordHash,
              sync_key: syncKey !== undefined && syncKey !== null ? syncKey : existing?.sync_key,
              created_at: existing?.created_at || new Date().toISOString(),
            });
            return {
              results: [] as T[],
              success: true,
              meta: createMeta(1),
            };
          }

          // Progress upsert: INSERT INTO progress ... ON CONFLICT
          if (q.includes("INSERT INTO progress")) {
            const [
              username,
              document_hash,
              percentage,
              progress,
              device,
              device_id,
              timestamp,
              title,
              authors,
              book_key,
            ] = boundParams;
            const key = `${username}:${document_hash}`;
            const existing = progressTable.get(key);
            progressTable.set(key, {
              username,
              document_hash,
              percentage,
              progress,
              device,
              device_id: device_id ?? null,
              timestamp,
              title: title !== undefined && title !== null ? title : existing?.title,
              authors: authors !== undefined && authors !== null ? authors : existing?.authors,
              book_key: book_key !== undefined && book_key !== null ? book_key : existing?.book_key,
            });
            return {
              results: [] as T[],
              success: true,
              meta: createMeta(1),
            };
          }

          // Progress update by book_key: UPDATE progress SET ... WHERE username = ? AND book_key = ?
          if (q.includes("UPDATE progress") && q.includes("WHERE username = ? AND book_key = ?")) {
            const [percentage, progress, device, device_id, timestamp, username, book_key, excludeHash] = boundParams;
            let changes = 0;
            for (const [k, record] of progressTable.entries()) {
              if (record.username === username && record.book_key === book_key && record.document_hash !== excludeHash) {
                record.percentage = percentage;
                record.progress = progress;
                record.device = device;
                record.device_id = device_id;
                record.timestamp = timestamp;
                changes++;
              }
            }
            return {
              results: [] as T[],
              success: true,
              meta: createMeta(changes),
            };
          }

          return {
            results: [] as T[],
            success: true,
            meta: createMeta(0),
          };
        },
      };

      return stmtObj as D1PreparedStatement;
    },

    async exec(query: string): Promise<D1ExecResult> {
      return { count: 1, duration: 0 };
    },

    async batch<T = unknown>(statements: D1PreparedStatement[]): Promise<D1Result<T>[]> {
      const results: D1Result<T>[] = [];
      for (const s of statements) {
        results.push(await s.all<T>());
      }
      return results;
    },

    async dump(): Promise<ArrayBuffer> {
      return new ArrayBuffer(0);
    },
  };

  return mockD1 as D1Database;
}
