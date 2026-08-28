import { Context, MiddlewareHandler } from "hono";
import { Env, KosyncErrors } from "./types";
import { getUserByUsername } from "./db";

/**
 * Hash a password using Web Crypto SHA-256.
 */
export async function hashPassword(password: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(`koreader_salt_${password}`);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Constant-time string comparison to prevent timing attacks.
 */
export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) {
    return false;
  }
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

/**
 * Validate that a field is non-empty string and does not contain illegal characters (e.g. colons).
 */
export function isValidKeyField(val: unknown): val is string {
  return typeof val === "string" && val.length > 0 && !val.includes(":");
}

export function isValidString(val: unknown): val is string {
  return typeof val === "string" && val.length > 0;
}

/**
 * Extract authentication credentials from request headers or body.
 */
export async function extractCredentials(
  c: Context<{ Bindings: Env; Variables: { username: string } }>
): Promise<{ username: string; userKey: string } | null> {
  const headerUser = c.req.header("x-auth-user");
  const headerKey = c.req.header("x-auth-key");

  if (isValidKeyField(headerUser) && isValidString(headerKey)) {
    return { username: headerUser, userKey: headerKey };
  }

  // Check Authorization header (e.g. Bearer or Basic)
  const authHeader = c.req.header("authorization");
  if (authHeader && authHeader.startsWith("Basic ")) {
    try {
      const decoded = atob(authHeader.slice(6));
      const colonIdx = decoded.indexOf(":");
      if (colonIdx > 0) {
        const username = decoded.slice(0, colonIdx);
        const userKey = decoded.slice(colonIdx + 1);
        if (isValidKeyField(username) && isValidString(userKey)) {
          return { username, userKey };
        }
      }
    } catch {
      // Ignore decoding failure
    }
  }

  // If method is POST and Content-Type is json, try body as fallback
  if (c.req.method === "POST" && c.req.header("content-type")?.includes("application/json")) {
    try {
      const body = await c.req.json().catch(() => null);
      if (body && isValidKeyField(body.username) && isValidString(body.password)) {
        return { username: body.username, userKey: body.password };
      }
    } catch {
      // Ignore body parsing failure
    }
  }

  return null;
}

/**
 * Authenticate credentials against D1 database.
 */
export async function authenticate(
  db: D1Database,
  username: string,
  userKey: string
): Promise<boolean> {
  const user = await getUserByUsername(db, username);
  if (!user) {
    return false;
  }

  const computedHash = await hashPassword(userKey);
  return timingSafeEqual(computedHash, user.password_hash);
}

/**
 * Hono Middleware requiring Kosync authentication.
 */
export const requireAuth: MiddlewareHandler<{
  Bindings: Env;
  Variables: { username: string };
}> = async (c, next) => {
  const creds = await extractCredentials(c);
  if (!creds) {
    return c.json(
      { code: KosyncErrors.UNAUTHORIZED.code, message: KosyncErrors.UNAUTHORIZED.message },
      KosyncErrors.UNAUTHORIZED.status
    );
  }

  const isValid = await authenticate(c.env.DB, creds.username, creds.userKey);
  if (!isValid) {
    return c.json(
      { code: KosyncErrors.UNAUTHORIZED.code, message: KosyncErrors.UNAUTHORIZED.message },
      KosyncErrors.UNAUTHORIZED.status
    );
  }

  c.set("username", creds.username);
  await next();
};
