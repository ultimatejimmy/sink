# KOReader Kosync Backend (Cloudflare Workers + D1)

[![Deploy to Cloudflare Workers](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/ultimatejimmy/sink)

A high-performance, serverless, self-hosted [KOReader](https://koreader.rocks/) reading progress synchronization backend implemented with [Hono](https://hono.dev/), TypeScript, and [Cloudflare D1](https://developers.cloudflare.com/d1/).

---

## Features

- **Kosync Protocol Compatible**: Native support for KOReader's progress synchronization protocol.
- **Serverless & Ultra-Fast**: Runs on Cloudflare's global edge network with sub-millisecond cold starts.
- **Edge Storage with D1**: Powered by Cloudflare D1 (serverless SQLite at the edge) for lightweight, low-latency, and zero-maintenance storage.
- **Secure Password Hashing**: Utilizes Web Crypto SHA-256 with salted constant-time verification.
- **1-Click Deployment**: Deploy to Cloudflare Workers with a single click.

---

## 1-Click Deployment

Click the button below to deploy this backend directly to your Cloudflare account:

[![Deploy to Cloudflare Workers](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/ultimatejimmy/sink)

---

## API Endpoints

All endpoints conform to the KOReader Kosync REST specification:

| Method | Endpoint | Description | Auth Required |
|---|---|---|---|
| `GET` | `/health` | Healthcheck and service status | No |
| `GET` | `/healthcheck` | Healthcheck endpoint (`{"state": "OK"}`) | No |
| `POST` | `/users/create` | Register a new user (`{"username", "password"}`) | No |
| `GET` / `POST` | `/users/auth` | Authenticate user credentials | Yes (`x-auth-user`, `x-auth-key`) |
| `GET` | `/syncs/progress/:document_hash` | Get reading progress for a document | Yes (`x-auth-user`, `x-auth-key`) |
| `PUT` | `/syncs/progress` | Upsert reading progress record | Yes (`x-auth-user`, `x-auth-key`) |

---

## Local Development & Setup

### 1. Prerequisites
- [Node.js](https://nodejs.org/) v18+
- [Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/)

### 2. Install Dependencies
```bash
npm install
```

### 3. Initialize D1 Database
Create the local D1 SQLite database tables using the schema:
```bash
npm run d1:init:local
```

### 4. Start Local Development Server
```bash
npm run dev
```
The server will be available at `http://localhost:8787`.

### 5. Run Unit & Integration Tests
```bash
npm test
```

---

## Production Cloudflare Deployment

### 1. Create Remote D1 Database
```bash
npx wrangler d1 create koreader_sync_db
```
Wrangler will output a `database_id`. Update your `wrangler.toml` file with this ID:
```toml
[[d1_databases]]
binding = "DB"
database_name = "koreader_sync_db"
database_id = "<YOUR_D1_DATABASE_ID>"
```

### 2. Apply Database Schema Remotely
```bash
npm run d1:init:remote
```

### 3. Deploy Worker
```bash
npm run deploy
```
Your worker will be live at `https://koreader-sync-server.<your-subdomain>.workers.dev`.
