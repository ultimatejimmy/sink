import { Hono } from "hono";
import { Env, CreateUserPayload, KosyncErrors } from "../types";
import {
  hashPassword,
  isValidKeyField,
  isValidString,
  extractCredentials,
  authenticate,
} from "../auth";
import { getUserByUsername, createUser } from "../db";

export const usersRouter = new Hono<{
  Bindings: Env;
  Variables: { username: string };
}>();

// POST /users/create
usersRouter.post("/create", async (c) => {
  if (c.env.ENABLE_USER_REGISTRATION === "false" || c.env.ENABLE_USER_REGISTRATION === "0") {
    return c.json(
      {
        code: KosyncErrors.REGISTRATION_DISABLED.code,
        message: KosyncErrors.REGISTRATION_DISABLED.message,
      },
      KosyncErrors.REGISTRATION_DISABLED.status
    );
  }

  let body: CreateUserPayload;
  try {
    body = await c.req.json<CreateUserPayload>();
  } catch {
    return c.json(
      {
        code: KosyncErrors.INVALID_FIELDS.code,
        message: KosyncErrors.INVALID_FIELDS.message,
      },
      KosyncErrors.INVALID_FIELDS.status
    );
  }

  const { username, password } = body;
  if (!isValidKeyField(username) || !isValidString(password)) {
    return c.json(
      {
        code: KosyncErrors.INVALID_FIELDS.code,
        message: KosyncErrors.INVALID_FIELDS.message,
      },
      KosyncErrors.INVALID_FIELDS.status
    );
  }

  try {
    const existingUser = await getUserByUsername(c.env.DB, username);
    if (existingUser) {
      return c.json(
        {
          code: KosyncErrors.USER_EXISTS.code,
          message: KosyncErrors.USER_EXISTS.message,
        },
        KosyncErrors.USER_EXISTS.status
      );
    }

    const passwordHash = await hashPassword(password);
    const success = await createUser(c.env.DB, username, passwordHash);

    if (!success) {
      return c.json(
        {
          code: KosyncErrors.INTERNAL.code,
          message: "Failed to insert user into database.",
        },
        500
      );
    }

    return c.json({ username }, 201);
  } catch (err: any) {
    console.error("User registration error:", err);
    return c.json(
      {
        code: KosyncErrors.INTERNAL.code,
        message: "Database error: " + (err.message || String(err)),
      },
      500
    );
  }
});

// Helper for auth logic (supports both GET and POST)
async function handleAuth(c: any) {
  const creds = await extractCredentials(c);
  if (!creds) {
    return c.json(
      {
        code: KosyncErrors.UNAUTHORIZED.code,
        message: KosyncErrors.UNAUTHORIZED.message,
      },
      KosyncErrors.UNAUTHORIZED.status
    );
  }

  try {
    const isValid = await authenticate(c.env.DB, creds.username, creds.userKey);
    if (!isValid) {
      return c.json(
        {
          code: KosyncErrors.UNAUTHORIZED.code,
          message: KosyncErrors.UNAUTHORIZED.message,
        },
        KosyncErrors.UNAUTHORIZED.status
      );
    }

    c.header("x-auth-user", creds.username);
    c.header("x-auth-token", `token_${creds.username}_${Date.now()}`);
    return c.json({ authorized: "OK" }, 200);
  } catch (err: any) {
    console.error("User authentication error:", err);
    return c.json(
      {
        code: KosyncErrors.INTERNAL.code,
        message: "Database error: " + (err.message || String(err)),
      },
      500
    );
  }
}

// POST /users/auth & GET /users/auth
usersRouter.get("/auth", handleAuth);
usersRouter.post("/auth", handleAuth);
