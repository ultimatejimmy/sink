# Sink: Private KOReader Progress Sync Solution

[![Deploy to Cloudflare Workers](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/ultimatejimmy/sink)

A complete, private reading progress synchronization solution for [KOReader](https://koreader.rocks/) on Kindle, Kobo, Android, and other e-readers, powered by a serverless **Cloudflare Worker** backend (Hono + Cloudflare D1) and a **non-intrusive KOReader Lua plugin**.

---

## Architecture Overview

```mermaid
flowchart LR
    subgraph Kindle [Kindle / KOReader Device]
        direction TB
        Hook["Lifecycle Hooks\n(Ready, Close, Suspend)"] -->|NetworkMgr:isOnline()| Check{Is Online?}
        Check -->|Yes| SilentSync["Silent Background Sync"]
        Check -->|No| Skip["Silently Skip\n(No Wi-Fi Popup)"]
        User["User 'Sync Now' Tap"] -->|NetworkMgr:runWhenOnline()| ManualSync["Prompt Wi-Fi & Sync"]
    end

    subgraph Edge [Cloudflare Edge Network]
        direction TB
        Worker["Hono Worker\n(Kosync REST API)"]
        D1[(Cloudflare D1\nSQLite Database)]
        Worker -->|Queries & Upserts| D1
    end

    SilentSync -->|HTTPS /syncs/progress| Worker
    ManualSync -->|HTTPS /syncs/progress| Worker
```

---

## Repository Structure

- [`backend/`](file:///backend) - Cloudflare Worker implementation using TypeScript, Hono, and Cloudflare D1. Includes 1-click deploy setup, D1 schema, and automated tests.
- [`sink.koplugin/`](file:///sink.koplugin) - KOReader user plugin optimized for e-ink devices, non-intrusive Wi-Fi management, and silent background synchronization.

---

## 1-Click Backend Deployment

Click the button below to deploy the backend to Cloudflare Workers:

[![Deploy to Cloudflare Workers](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/ultimatejimmy/sink)

---

## Quickstart Guide

### 1. Backend Setup
```bash
cd backend
npm install
npm run d1:init:local   # Initialize local D1 SQLite database
npm test                # Run Vitest test suite
npm run dev             # Start local development server
```

For production deployment instructions, see [`backend/README.md`](file:///backend/README.md).

### 2. KOReader Plugin Installation
1. Copy the [`sink.koplugin`](file:///sink.koplugin) folder to your device's `koreader/plugins/` directory.
2. Restart KOReader.
3. Open the menu -> **Sink Progress Sync** -> configure your **Server URL**, **Username**, and **User Key / Password**.
4. Tap **Register New Account** (or **Test Connection / Login**).

For full details, see [`sink.koplugin/README.md`](file:///sink.koplugin/README.md).

---

## License

MIT License
