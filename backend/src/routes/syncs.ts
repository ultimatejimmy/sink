import { Hono } from "hono";
import { Env, UpdateProgressPayload, ProgressResponse, KosyncErrors } from "../types";
import { requireAuth, isValidKeyField, isValidString } from "../auth";
import { getProgress, upsertProgress } from "../db";

export const syncsRouter = new Hono<{
  Bindings: Env;
  Variables: { username: string };
}>();

// Apply auth middleware to all sync routes
syncsRouter.use("*", requireAuth);

// GET /syncs/progress/:document_hash
syncsRouter.get("/progress/:document_hash", async (c) => {
  const username = c.get("username");
  const documentHash = c.req.param("document_hash");

  if (!isValidKeyField(documentHash)) {
    return c.json(
      {
        code: KosyncErrors.MISSING_DOCUMENT.code,
        message: KosyncErrors.MISSING_DOCUMENT.message,
      },
      KosyncErrors.MISSING_DOCUMENT.status
    );
  }

  const record = await getProgress(c.env.DB, username, documentHash);

  if (!record) {
    // Kosync spec: return empty JSON object when no progress exists for document
    return c.json({}, 200);
  }

  const response: ProgressResponse = {
    document: record.document_hash,
    percentage: record.percentage,
    progress: record.progress,
    device: record.device,
    device_id: record.device_id ?? undefined,
    timestamp: record.timestamp,
  };

  return c.json(response, 200);
});

// PUT /syncs/progress
syncsRouter.put("/progress", async (c) => {
  const username = c.get("username");

  let body: UpdateProgressPayload;
  try {
    body = await c.req.json<UpdateProgressPayload>();
  } catch {
    return c.json(
      {
        code: KosyncErrors.INVALID_FIELDS.code,
        message: KosyncErrors.INVALID_FIELDS.message,
      },
      KosyncErrors.INVALID_FIELDS.status
    );
  }

  const doc = body.document || body.document_hash;
  if (!isValidKeyField(doc)) {
    return c.json(
      {
        code: KosyncErrors.MISSING_DOCUMENT.code,
        message: KosyncErrors.MISSING_DOCUMENT.message,
      },
      KosyncErrors.MISSING_DOCUMENT.status
    );
  }

  const percentage =
    typeof body.percentage === "number"
      ? body.percentage
      : typeof body.percentage === "string"
      ? parseFloat(body.percentage)
      : NaN;

  const progress = body.progress;
  const device = body.device;
  const deviceId = body.device_id || null;

  if (isNaN(percentage) || !isValidString(progress) || !isValidString(device)) {
    return c.json(
      {
        code: KosyncErrors.INVALID_FIELDS.code,
        message: KosyncErrors.INVALID_FIELDS.message,
      },
      KosyncErrors.INVALID_FIELDS.status
    );
  }

  const timestamp = Math.floor(Date.now() / 1000);

  const success = await upsertProgress(c.env.DB, {
    username,
    document_hash: doc,
    percentage,
    progress,
    device,
    device_id: deviceId,
    timestamp,
  });

  if (!success) {
    return c.json(
      {
        code: KosyncErrors.INTERNAL.code,
        message: KosyncErrors.INTERNAL.message,
      },
      KosyncErrors.INTERNAL.status
    );
  }

  return c.json(
    {
      document: doc,
      timestamp,
    },
    200
  );
});
