import { Hono } from "hono";
import { Env, UpdateProgressPayload, ProgressResponse, KosyncErrors, normalizeBookKey } from "../types";
import { requireAuth, isValidKeyField, isValidString } from "../auth";
import {
  getProgress,
  upsertProgress,
  upsertDevice,
  getDevicesForUser,
  removeDevice,
  getBooksForUser,
  deleteBookProgress,
  getXrayCache,
  upsertXrayCache,
} from "../db";

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

  const queryTitle = c.req.query("title");
  const queryAuthors = c.req.query("authors");
  let bookKey = c.req.query("book_key") || null;
  if (!bookKey && queryTitle) {
    bookKey = normalizeBookKey(queryTitle, queryAuthors);
  }

  const altHashesParam = c.req.query("alt_hashes");
  const altHashes = altHashesParam ? altHashesParam.split(",").map((s) => s.trim()).filter(Boolean) : null;

  const record = await getProgress(c.env.DB, username, documentHash, bookKey, altHashes);

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

  const title = body.title || body.metadata?.title || null;
  const authors = body.authors || body.metadata?.authors || null;
  const bookKey = body.book_key || (title ? normalizeBookKey(title, authors) : null);
  const altHashes = body.alt_hashes || null;

  const success = await upsertProgress(c.env.DB, {
    username,
    document_hash: doc,
    percentage,
    progress,
    device,
    device_id: deviceId,
    timestamp,
    title,
    authors,
    book_key: bookKey,
    alt_hashes: altHashes,
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

  // Record active device
  try {
    const devId = deviceId || `${device.toLowerCase().replace(/\s+/g, "_")}`;
    await upsertDevice(c.env.DB, username, devId, device);
  } catch (err) {
    console.warn("Error tracking device in progress update:", err);
  }

  return c.json(
    {
      document: doc,
      timestamp,
    },
    200
  );
});

// GET /syncs/devices -> List paired devices for user
syncsRouter.get("/devices", async (c) => {
  const username = c.get("username");
  const devices = await getDevicesForUser(c.env.DB, username);
  return c.json({ devices }, 200);
});

// DELETE /syncs/devices/:device_id -> Remove paired device
syncsRouter.delete("/devices/:device_id", async (c) => {
  const username = c.get("username");
  const deviceId = c.req.param("device_id");
  const success = await removeDevice(c.env.DB, username, deviceId);
  return c.json({ success }, success ? 200 : 500);
});

// GET /syncs/books -> List books in cloud library
syncsRouter.get("/books", async (c) => {
  const username = c.get("username");
  const books = await getBooksForUser(c.env.DB, username);
  return c.json({ books }, 200);
});

// DELETE /syncs/books/:document_hash -> Remove book progress from cloud
syncsRouter.delete("/books/:document_hash", async (c) => {
  const username = c.get("username");
  const docHash = c.req.param("document_hash");
  const success = await deleteBookProgress(c.env.DB, username, docHash);
  return c.json({ success }, success ? 200 : 500);
});

// GET /syncs/xray/:document_hash -> Get X-Ray cache
syncsRouter.get("/xray/:document_hash", async (c) => {
  const username = c.get("username");
  const docHash = c.req.param("document_hash");
  const bookKey = c.req.query("book_key") || null;

  const record = await getXrayCache(c.env.DB, username, bookKey, docHash);
  if (!record) {
    return c.json({}, 200);
  }

  return c.json(
    {
      book_key: record.book_key,
      document_hash: record.document_hash,
      cache_data: record.cache_data,
      timestamp: record.timestamp,
    },
    200
  );
});

// PUT /syncs/xray -> Upsert X-Ray cache
syncsRouter.put("/xray", async (c) => {
  const username = c.get("username");
  let body: { document?: string; document_hash?: string; book_key?: string; cache_data?: string; timestamp?: number };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "Invalid JSON" }, 400);
  }

  const doc = body.document || body.document_hash;
  const bookKey = body.book_key || doc;
  const cacheData = body.cache_data;
  const timestamp = body.timestamp || Math.floor(Date.now() / 1000);

  if (!doc || !bookKey || !cacheData) {
    return c.json({ error: "Missing required fields (document, book_key, cache_data)" }, 400);
  }

  const success = await upsertXrayCache(c.env.DB, username, bookKey, doc, cacheData, timestamp);
  return c.json({ success, timestamp }, success ? 200 : 500);
});

// POST /syncs/upgrade -> One-button backend upgrade via Cloudflare Deploy Hook
syncsRouter.post("/upgrade", async (c) => {
  const deployHook = c.env.DEPLOY_HOOK_URL;
  if (!deployHook) {
    return c.json(
      {
        success: false,
        error: "DEPLOY_HOOK_URL is not configured on Cloudflare Worker.",
        guide: "Create a Deploy Hook in Cloudflare Workers Settings -> Deployments, and add it as DEPLOY_HOOK_URL in Worker Environment Variables.",
      },
      400
    );
  }

  try {
    const res = await fetch(deployHook, { method: "POST" });
    if (res.ok) {
      return c.json({
        success: true,
        message: "Cloudflare deployment triggered successfully! Your Worker will rebuild in ~30 seconds.",
      });
    } else {
      return c.json(
        {
          success: false,
          error: `Deploy hook returned HTTP ${res.status}: ${await res.text()}`,
        },
        502
      );
    }
  } catch (err: any) {
    return c.json(
      {
        success: false,
        error: `Failed to trigger deploy hook: ${err.message || String(err)}`,
      },
      500
    );
  }
});
