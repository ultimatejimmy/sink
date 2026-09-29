![Platform](https://img.shields.io/badge/platform-KOReader-green.svg)
![License](https://img.shields.io/badge/license-AGPL_3.0-yellow.svg)
![Status](https://img.shields.io/badge/status-active-brightgreen.svg)
[![liberapay](https://img.shields.io/liberapay/patrons/ultimatejimmy.svg?logo=liberapay)](https://liberapay.com/ultimatejimmy)
[!["Buy Me A Coffee"](https://img.shields.io/badge/-buy_me_a%C2%A0coffee-gray?logo=buy-me-a-coffee)](https://www.buymeacoffee.com/ultimatejimmy)
[![ko-fi](https://shields.io/badge/kofi-Support-ff5f5f?logo=ko-fi&style=flat)](https://ko-fi.com/G0J627UAY9)
# Sink: Private KOReader Progress Sync Solution

<a href="https://deploy.workers.cloudflare.com/?url=https://github.com/ultimatejimmy/sink" target="_blank" rel="noopener noreferrer"><img src="https://deploy.workers.cloudflare.com/button" alt="Deploy to Cloudflare Workers" /></a>

A complete, private reading progress synchronization solution for [KOReader](https://koreader.rocks/) on Kindle, Kobo, Android, and other e-readers, powered by a serverless **Cloudflare Worker** backend (Hono + Cloudflare D1) and a **non-intrusive KOReader Lua plugin**.

---

## Zero-Password Device Pairing

Pair your Kindle or KOReader device in seconds without typing passwords on an e-ink keyboard:

1. **On your E-Reader**: Tap **Tools** &rarr; **Sink** &rarr; **Pair Device (Phone/PC)** to display a 6-character code (e.g., `K9X 2P4`).
2. **On your Phone or PC**: Open your Sink web dashboard and enter the code.
3. **Done**: Your device connects automatically and starts syncing reading progress.

---

## Repository Structure

- [`backend/`](./backend) - Cloudflare Worker implementation using TypeScript, Hono, and Cloudflare D1. Includes 1-click deploy setup, pairing endpoints, and automated tests.
- [`sink.koplugin/`](./sink.koplugin) - KOReader user plugin with seamless code pairing, non-intrusive Wi-Fi management, and silent background synchronization.

---

## 1-Click Backend Deployment

Click the button below to deploy the backend to Cloudflare Workers:

<a href="https://deploy.workers.cloudflare.com/?url=https://github.com/ultimatejimmy/sink" target="_blank" rel="noopener noreferrer"><img src="https://deploy.workers.cloudflare.com/button" alt="Deploy to Cloudflare Workers" /></a>

---

## Quickstart Guide

### 1. Deploy the Backend
Deploy via the button above, or run locally:
```bash
cd backend
npm install
npm test                # Run Vitest test suite
npm run dev             # Start local development server
```

### 2. KOReader Plugin Installation
1. Copy the [`sink.koplugin`](./sink.koplugin) folder to your device's `koreader/plugins/` directory.
2. Restart KOReader.
3. Open the top menu &rarr; **Tools** &rarr; **Sink** &rarr; **Pair Device (Phone/PC)**.
4. Open your Worker URL on your phone or PC, enter the 6-character code and choose a 4-digit PIN, and tap **Connect E-Reader**.
5. Your device is now connected and reading progress will sync automatically!

---

## License

GNU Affero General Public License v3.0 (AGPL-3.0). See [COPYING](./COPYING) for details.

## Support me

[ko-fi](https://ko-fi.com/G0J627UAY9)

[liberapay](https://liberapay.com/ultimatejimmy)  

[Buy me a coffee](https://www.buymeacoffee.com/ultimatejimmy)
