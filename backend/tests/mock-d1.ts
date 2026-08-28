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

          // User insert: INSERT INTO users (username, password_hash) VALUES (?, ?)
          if (q.includes("INSERT INTO users")) {
            const username = boundParams[0];
            const passwordHash = boundParams[1];
            usersTable.set(username, {
              username,
              password_hash: passwordHash,
              created_at: new Date().toISOString(),
            });
            return {
              results: [] as T[],
              success: true,
              meta: createMeta(1),
            };
          }

          // Progress upsert: INSERT INTO progress ... ON CONFLICT
          if (q.includes("INSERT INTO progress")) {
            const [username, document_hash, percentage, progress, device, device_id, timestamp] =
              boundParams;
            const key = `${username}:${document_hash}`;
            progressTable.set(key, {
              username,
              document_hash,
              percentage,
              progress,
              device,
              device_id: device_id ?? null,
              timestamp,
            });
            return {
              results: [] as T[],
              success: true,
              meta: createMeta(1),
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
