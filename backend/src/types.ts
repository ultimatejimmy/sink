export interface Env {
  DB: D1Database;
  ENABLE_USER_REGISTRATION?: string;
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
