import { Hono } from "hono";
import { cors } from "hono/cors";
import { Env, KosyncErrors } from "./types";
import { healthRouter } from "./routes/health";
import { usersRouter } from "./routes/users";
import { syncsRouter } from "./routes/syncs";
import { ensureDatabase } from "./db";

const app = new Hono<{ Bindings: Env; Variables: { username: string } }>();

// Enable CORS for web clients / dashboard
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

// Root Route: Interactive Web Onboarding Page (for browsers) / JSON Info (for APIs)
app.get("/", async (c) => {
  const acceptHeader = c.req.header("accept") || "";

  // If request is from API or KOReader, return JSON
  if (
    !acceptHeader.includes("text/html") &&
    (acceptHeader.includes("application/json") ||
      acceptHeader.includes("application/vnd.koreader.v1+json"))
  ) {
    return c.json({
      service: "KOReader Kosync Server",
      status: "running",
      version: "1.0.0",
      docs: "https://github.com/ultimatejimmy/sink",
    });
  }

  // Ensure database tables exist
  let dbStatus = "Connected & Ready";
  try {
    await ensureDatabase(c.env.DB);
  } catch (e) {
    dbStatus = "Database Error: " + String(e);
  }

  const origin = new URL(c.req.url).origin;

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Sink — KOReader Sync Server</title>
  <style>
    :root {
      --bg: #0f172a;
      --card-bg: #1e293b;
      --border: #334155;
      --text: #f8fafc;
      --text-muted: #94a3b8;
      --primary: #38bdf8;
      --primary-hover: #0284c7;
      --success: #4ade80;
      --error: #f87171;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body { background-color: var(--bg); color: var(--text); padding: 2rem 1rem; display: flex; justify-content: center; min-height: 100vh; }
    .container { max-width: 680px; width: 100%; display: flex; flex-direction: column; gap: 1.5rem; }
    .header { text-align: center; }
    .header h1 { font-size: 2.2rem; font-weight: 700; color: var(--text); margin-bottom: 0.5rem; }
    .header p { color: var(--text-muted); font-size: 1.05rem; }
    .badge { display: inline-flex; align-items: center; gap: 0.5rem; background: rgba(74, 222, 128, 0.1); color: var(--success); border: 1px solid rgba(74, 222, 128, 0.3); padding: 0.35rem 0.85rem; border-radius: 9999px; font-size: 0.875rem; font-weight: 500; margin-top: 0.75rem; }
    .card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 1rem; padding: 1.5rem; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); }
    .card h2 { font-size: 1.25rem; margin-bottom: 1rem; color: var(--primary); display: flex; align-items: center; gap: 0.5rem; }
    .input-group { margin-bottom: 1rem; display: flex; flex-direction: column; gap: 0.35rem; }
    label { font-size: 0.875rem; color: var(--text-muted); font-weight: 500; }
    input[type="text"], input[type="password"] { background: #0f172a; border: 1px solid var(--border); color: var(--text); padding: 0.65rem 0.85rem; border-radius: 0.5rem; font-size: 1rem; width: 100%; outline: none; }
    input:focus { border-color: var(--primary); }
    .copy-box { display: flex; gap: 0.5rem; background: #0f172a; border: 1px solid var(--border); padding: 0.5rem 0.75rem; border-radius: 0.5rem; align-items: center; justify-content: space-between; }
    .copy-box code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--primary); font-size: 0.95rem; word-break: break-all; }
    button { background: var(--primary); color: #0f172a; border: none; padding: 0.65rem 1.25rem; border-radius: 0.5rem; font-weight: 600; font-size: 0.95rem; cursor: pointer; transition: all 0.15s ease; }
    button:hover { background: var(--primary-hover); color: white; }
    .btn-copy { background: var(--border); color: var(--text); padding: 0.4rem 0.75rem; font-size: 0.85rem; }
    .btn-copy:hover { background: #475569; }
    ol { padding-left: 1.25rem; color: var(--text-muted); line-height: 1.6; }
    li { margin-bottom: 0.5rem; }
    li strong { color: var(--text); }
    .alert { padding: 0.75rem 1rem; border-radius: 0.5rem; font-size: 0.9rem; margin-top: 1rem; display: none; }
    .alert.success { background: rgba(74, 222, 128, 0.15); border: 1px solid var(--success); color: var(--success); }
    .alert.error { background: rgba(248, 113, 113, 0.15); border: 1px solid var(--error); color: var(--error); }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>Sink Sync Server</h1>
      <p>Private KOReader reading progress sync on Cloudflare</p>
      <div class="badge">● D1 Database: ${dbStatus}</div>
    </div>

    <!-- Quick Account Registration -->
    <div class="card">
      <h2>1. Create Sync Account</h2>
      <form id="regForm">
        <div class="input-group">
          <label for="username">Username</label>
          <input type="text" id="username" name="username" placeholder="e.g. reader" required />
        </div>
        <div class="input-group">
          <label for="password">Password / Secret Key</label>
          <input type="password" id="password" name="password" placeholder="••••••••" required />
        </div>
        <button type="submit" id="btnSubmit">Create Account</button>
        <div id="alertBox" class="alert"></div>
      </form>
    </div>

    <!-- KOReader Configuration Guide -->
    <div class="card">
      <h2>2. Configure KOReader</h2>
      <ol>
        <li>
          Copy your <strong>Server URL</strong>:
          <div class="copy-box" style="margin: 0.5rem 0;">
            <code id="serverUrl">${origin}</code>
            <button class="btn-copy" onclick="copyUrl()">Copy</button>
          </div>
        </li>
        <li>Open KOReader on your Kindle, Kobo, or Android device.</li>
        <li>Open the top menu &rarr; select <strong>Sink Progress Sync</strong>.</li>
        <li>Paste your <strong>Server URL</strong> and enter your <strong>Username</strong> and <strong>Password</strong>.</li>
        <li>Tap <strong>Test Connection / Login</strong> &mdash; you're all set!</li>
      </ol>
    </div>
  </div>

  <script>
    function copyUrl() {
      const url = document.getElementById('serverUrl').innerText;
      navigator.clipboard.writeText(url);
      alert('Server URL copied to clipboard!');
    }

    document.getElementById('regForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const alertBox = document.getElementById('alertBox');
      const btn = document.getElementById('btnSubmit');
      const username = document.getElementById('username').value.trim();
      const password = document.getElementById('password').value;

      btn.disabled = true;
      btn.innerText = 'Creating...';
      alertBox.style.display = 'none';

      try {
        const res = await fetch('/users/create', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ username, password })
        });
        const data = await res.json();

        if (res.status === 201) {
          alertBox.className = 'alert success';
          alertBox.innerText = '✓ Account "' + username + '" successfully registered! You can now log into KOReader.';
          alertBox.style.display = 'block';
        } else {
          alertBox.className = 'alert error';
          alertBox.innerText = data.message || 'Error creating account (HTTP ' + res.status + ')';
          alertBox.style.display = 'block';
        }
      } catch (err) {
        alertBox.className = 'alert error';
        alertBox.innerText = 'Network error: ' + err.message;
        alertBox.style.display = 'block';
      } finally {
        btn.disabled = false;
        btn.innerText = 'Create Account';
      }
    });
  </script>
</body>
</html>`;

  return c.html(html);
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
