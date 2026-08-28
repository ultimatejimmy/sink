# Sink Backend (Cloudflare Workers + D1)

[![Deploy to Cloudflare Workers](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/ultimatejimmy/sink)

A high-performance, serverless, self-hosted [KOReader](https://koreader.rocks/) reading progress synchronization backend implemented with [Hono](https://hono.dev/), TypeScript, and [Cloudflare D1](https://developers.cloudflare.com/d1/).

---

## Features

- **Kosync Protocol Compatible**: Native support for KOReader's progress synchronization protocol.
- **Serverless & Ultra-Fast**: Runs on Cloudflare's global edge network with sub-millisecond cold starts.
- **Edge Storage with D1**: Powered by Cloudflare D1 (serverless SQLite at the edge) for lightweight, low-latency, and zero-maintenance storage.
- **Zero-Config Database**: Auto-bootstraps database schema on first run.
- **Built-in Web Onboarding**: Visit your worker URL in any browser to create accounts and view setup guides.
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
| `GET` | `/` | Web onboarding page (browser) or JSON info (API) | No |
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

### 3. Start Local Development Server
```bash
npm run dev
```
The server will be available at `http://localhost:8787`.

### 4. Run Unit & Integration Tests
```bash
npm test
```

---

## Production Cloudflare Deployment via CLI

```bash
# 1. Create remote D1 database
npx wrangler d1 create koreader_sync_db

# 2. Deploy Worker
npm run deploy
```
Your worker will be live at `https://sink.<your-subdomain>.workers.dev`.
