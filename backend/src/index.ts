import { Hono } from "hono";
import { cors } from "hono/cors";
import { Env, KosyncErrors } from "./types";
import { healthRouter } from "./routes/health";
import { usersRouter } from "./routes/users";
import { syncsRouter } from "./routes/syncs";
import { sessionRouter } from "./routes/session";
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
app.route("/api/session", sessionRouter);

// Root Route: Interactive Mobile Web Pairing Portal / JSON Info (for APIs)
app.get("/", async (c) => {
  const acceptHeader = c.req.header("accept") || "";

  // If request is from API or KOReader, return JSON
  if (
    !acceptHeader.includes("text/html") &&
    (acceptHeader.includes("application/json") ||
      acceptHeader.includes("application/vnd.koreader.v1+json"))
  ) {
    return c.json({
      service: "Sink KOReader Sync Server",
      status: "running",
      version: "1.0.0",
      docs: "https://github.com/ultimatejimmy/sink",
    });
  }

  // Ensure database tables exist
  let dbStatus = "Connected & Ready";
  try {
    if (c.env.DB) {
      await ensureDatabase(c.env.DB);
    }
  } catch (e) {
    dbStatus = "Database Error: " + String(e);
  }

  const origin = new URL(c.req.url).origin;

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Sink — KOReader Device Pairing</title>
  <style>
    :root {
      --bg: #090d16;
      --card-bg: #131d2e;
      --border: #223249;
      --text: #f1f5f9;
      --text-muted: #94a3b8;
      --primary: #38bdf8;
      --primary-hover: #7dd3fc;
      --success: #34d399;
      --error: #f87171;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body { background-color: var(--bg); color: var(--text); padding: 1.5rem 1rem; display: flex; justify-content: center; align-items: center; min-height: 100vh; }
    .card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 1.25rem; padding: 1.75rem; max-width: 480px; width: 100%; box-shadow: 0 20px 40px -10px rgba(0,0,0,0.6); }
    .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1.25rem; }
    .header h1 { font-size: 1.4rem; font-weight: 800; color: var(--primary); letter-spacing: -0.5px; }
    .badge { font-size: 0.75rem; font-weight: 700; color: var(--success); background: rgba(52, 211, 153, 0.12); border: 1px solid rgba(52, 211, 153, 0.3); padding: 4px 10px; border-radius: 9999px; }
    .notice { background: rgba(56, 189, 248, 0.08); border: 1px solid rgba(56, 189, 248, 0.25); border-radius: 12px; padding: 12px 14px; margin-bottom: 1.25rem; font-size: 0.82rem; color: #cbd5e1; line-height: 1.45; }
    .notice strong { color: var(--primary); }
    .step-title { font-size: 1.1rem; font-weight: 800; margin-bottom: 0.5rem; text-align: center; }
    .step-desc { font-size: 0.85rem; color: var(--text-muted); text-align: center; margin-bottom: 1.25rem; line-height: 1.45; }
    .code-input-wrap { max-width: 260px; margin: 0 auto 1.25rem auto; }
    .code-input { width: 100%; background: #0b121e; border: 2px solid var(--primary); color: var(--primary); border-radius: 12px; padding: 12px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 1.75rem; font-weight: 800; letter-spacing: 6px; text-transform: uppercase; text-align: center; outline: none; box-shadow: 0 0 15px rgba(56, 189, 248, 0.15); }
    .code-input:focus { border-color: var(--primary-hover); box-shadow: 0 0 20px rgba(56, 189, 248, 0.3); }
    .btn-primary { width: 100%; background: var(--primary); color: #090d16; border: none; border-radius: 12px; padding: 14px; font-size: 1rem; font-weight: 800; cursor: pointer; transition: all 0.15s ease; display: flex; align-items: center; justify-content: center; gap: 6px; }
    .btn-primary:hover { background: var(--primary-hover); }
    .btn-primary:disabled { background: #1e293b; color: #64748b; cursor: not-allowed; }
    .alert { padding: 12px 14px; border-radius: 10px; font-size: 0.85rem; margin-top: 1rem; display: none; line-height: 1.45; font-weight: 600; text-align: center; }
    .alert.success { background: rgba(52, 211, 153, 0.15); border: 1px solid var(--success); color: var(--success); }
    .alert.error { background: rgba(248, 113, 113, 0.15); border: 1px solid var(--error); color: var(--error); }
    .footer-help { margin-top: 1.5rem; padding-top: 1rem; border-top: 1px solid var(--border); font-size: 0.78rem; color: var(--text-muted); line-height: 1.5; }
  </style>
</head>
<body>
  <div class="card">
    <div class="header">
      <h1>Sink</h1>
      <span class="badge">● Online</span>
    </div>

    <div class="notice">
      🔒 <strong>Instant Device Pairing</strong>: No passwords to remember or type on your Kindle. Enter the 6-character code shown on your e-reader to pair it instantly.
    </div>

    <div class="step-title">Enter Pairing Code</div>
    <p class="step-desc">
      On your Kindle / KOReader device, tap <strong>Tools &rarr; Sink &rarr; Pair Device</strong> to see your 6-character code.
    </p>

    <form id="pairForm">
      <div class="code-input-wrap">
        <input
          type="text"
          id="pairingCode"
          class="code-input"
          placeholder="CODE"
          maxlength="6"
          autocomplete="off"
          autocorrect="off"
          autocapitalize="characters"
          spellcheck="false"
          autofocus
        />
      </div>

      <button type="submit" id="btnSubmit" class="btn-primary">
        <span>Connect E-Reader &rarr;</span>
      </button>

      <div id="alertBox" class="alert"></div>
    </form>

    <div class="footer-help">
      <strong>How it works:</strong> All devices paired with this server sync reading progress together automatically and silently in the background.
    </div>
  </div>

  <script>
    // Auto-fill pairing code if passed in URL: ?s=CODE
    window.addEventListener('DOMContentLoaded', () => {
      const params = new URLSearchParams(window.location.search);
      const code = (params.get('s') || '').trim().toUpperCase();
      const input = document.getElementById('pairingCode');
      if (code && code.length >= 4) {
        input.value = code;
        document.getElementById('btnSubmit').focus();
      }
    });

    document.getElementById('pairForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const alertBox = document.getElementById('alertBox');
      const btn = document.getElementById('btnSubmit');
      const code = document.getElementById('pairingCode').value.trim().toUpperCase();

      if (!code || code.length < 4) {
        alertBox.className = 'alert error';
        alertBox.innerText = 'Please enter the 6-character code from your e-reader screen.';
        alertBox.style.display = 'block';
        return;
      }

      btn.disabled = true;
      btn.innerText = 'Connecting...';
      alertBox.style.display = 'none';

      try {
        const res = await fetch('/api/session/' + encodeURIComponent(code) + '/submit', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ username: 'primary_reader' })
        });
        const data = await res.json();

        if (res.ok && data.success) {
          alertBox.className = 'alert success';
          alertBox.innerText = '✓ Device paired successfully! Look at your e-reader screen.';
          alertBox.style.display = 'block';
          btn.innerText = '✓ Connected!';
        } else {
          alertBox.className = 'alert error';
          alertBox.innerText = data.error || data.message || 'Invalid or expired code. Please check the code on your device.';
          alertBox.style.display = 'block';
          btn.disabled = false;
          btn.innerText = 'Connect E-Reader →';
        }
      } catch (err) {
        alertBox.className = 'alert error';
        alertBox.innerText = 'Network error: ' + err.message;
        alertBox.style.display = 'block';
        btn.disabled = false;
        btn.innerText = 'Connect E-Reader →';
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
