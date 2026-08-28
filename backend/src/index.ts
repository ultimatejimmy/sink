import { Hono } from "hono";
import { cors } from "hono/cors";
import { Env, KosyncErrors } from "./types";
import { healthRouter } from "./routes/health";
import { usersRouter } from "./routes/users";
import { syncsRouter } from "./routes/syncs";

const app = new Hono<{ Bindings: Env; Variables: { username: string } }>();

// Enable CORS for any web dashboards / clients
app.use(
  "*",
  cors({
    origin: "*",
    allowHeaders: [
      "Content-Type",
      "Authorization",
      "X-Auth-User",
      "X-Auth-Key",
      "Accept",
    ],
    allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    exposeHeaders: ["X-Auth-User", "X-Auth-Token"],
  })
);

// Mount route modules
app.route("/", healthRouter);
app.route("/users", usersRouter);
app.route("/syncs", syncsRouter);

// Root greeting & info
app.get("/", (c) => {
  return c.json({
    service: "KOReader Kosync Server",
    status: "running",
    version: "1.0.0",
    docs: "https://github.com/koreader/koreader/wiki/Syncing",
  });
});

// Custom 404 handler
app.notFound((c) => {
  return c.json(
    {
      code: 404,
      message: "Endpoint not found",
    },
    404
  );
});

// Global error handler
app.onError((err, c) => {
  console.error("Unhandled server error:", err);
  return c.json(
    {
      code: KosyncErrors.INTERNAL.code,
      message: KosyncErrors.INTERNAL.message,
    },
    KosyncErrors.INTERNAL.status
  );
});

export default app;
