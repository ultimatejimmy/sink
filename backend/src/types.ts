export interface Env {
  DB: D1Database;
  ENABLE_USER_REGISTRATION?: string;
  ADMIN_PIN?: string;
  DEPLOY_HOOK_URL?: string;
}

export interface DeviceRecord {
  username: string;
  device_id: string;
  device_model: string;
  created_at: number;
  last_sync_at: number;
}

export interface XrayCacheRecord {
  username: string;
  book_key: string;
  document_hash: string;
  cache_data: string;
  timestamp: number;
}

export interface User {
  username: string;
  password_hash: string;
  sync_key?: string;
  created_at: string;
}

export interface ProgressRecord {
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
}

export interface CreateUserPayload {
  username?: string;
  password?: string;
}

export interface AuthUserPayload {
  username?: string;
  password?: string;
}

export interface UpdateProgressPayload {
  document?: string;
  document_hash?: string;
  percentage?: number | string;
  progress?: string;
  device?: string;
  device_id?: string;
  metadata?: {
    filename?: string;
    title?: string;
    authors?: string;
  };
  title?: string;
  authors?: string;
  book_key?: string;
  alt_hashes?: string[];
}

export function normalizeBookKey(title?: string | null, authors?: string | null): string {
  if (!title || !title.trim()) return "";
  let cleanTitle = title
    .toLowerCase()
    .replace(/\(.*?\)/g, "")
    .replace(/\[.*?\]/g, "")
    .replace(/^(the|a|an)\s+/i, "")
    .replace(/,\s*(the|a|an)$/i, "")
    .replace(/[^a-z0-9\s]/g, " ")
    .trim()
    .replace(/\s+/g, " ");

  let cleanAuthor = "";
  if (authors && authors.trim()) {
    cleanAuthor = authors
      .toLowerCase()
      .replace(/[^a-z0-9\s]/g, " ")
      .trim()
      .split(/\s+/)
      .filter(Boolean)
      .sort()
      .join(" ");
  }

  return cleanAuthor ? `${cleanTitle}::${cleanAuthor}` : cleanTitle;
}

export interface ProgressResponse {
  document?: string;
  percentage?: number;
  progress?: string;
  device?: string;
  device_id?: string;
  timestamp?: number;
}

export const KosyncErrors = {
  NO_DB: { status: 502, code: 1000, message: "Cannot connect to database." },
  INTERNAL: { status: 502, code: 2000, message: "Unknown server error." },
  UNAUTHORIZED: { status: 401, code: 2001, message: "Unauthorized" },
  USER_EXISTS: { status: 402, code: 2002, message: "Username is already registered." },
  INVALID_FIELDS: { status: 403, code: 2003, message: "Invalid request" },
  MISSING_DOCUMENT: { status: 403, code: 2004, message: "Field 'document' not provided." },
  REGISTRATION_DISABLED: { status: 402, code: 2005, message: "User registration is disabled." },
} as const;
