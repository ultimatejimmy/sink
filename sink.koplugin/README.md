# Sink Progress Sync (KOReader Plugin)

A non-intrusive, battery-friendly reading progress synchronization plugin for [KOReader](https://koreader.rocks/) on Kindle, Kobo, Android, and other e-readers.

---

## Highlights & Design Philosophy

- **Zero Intrusive Wi-Fi Prompts**: Background syncs automatically check `NetworkMgr:isOnline()`. If your device is offline or in airplane mode, it silently skips syncing without waking Wi-Fi or showing popups.
- **On-Demand Manual Sync**: Tapping **"Sync Now"** uses `NetworkMgr:runWhenOnline()` to prompt for a Wi-Fi connection only when you explicitly request it.
- **Silent Background Error Suppression**: Background network timeouts or connection drops are logged silently without disrupting your reading flow with alerts or toasts.
- **Full Cloudflare Worker Backend Compatibility**: Pairs with our high-speed Cloudflare Worker + D1 backend for private, zero-cost, multi-device synchronization.

---

## Installation

1. Connect your Kindle / e-reader to your computer via USB.
2. Navigate to your KOReader plugins directory:
   - **Kindle / Kobo**: `koreader/plugins/`
   - **Android**: `Android/data/org.koreader.launcher/files/koreader/plugins/`
3. Copy the entire `sink.koplugin` folder into the `plugins/` directory:
   ```
   koreader/
   └── plugins/
       └── sink.koplugin/
           ├── _meta.lua
           ├── main.lua
           └── README.md
   ```
4. Safely eject your device and restart KOReader.

---

## Configuration

1. Open the KOReader main menu (top menu bar) and select **Sink Progress Sync**.
2. Tap **Server URL** and enter your deployed backend URL (e.g. `https://koreader-sync-server.your-subdomain.workers.dev`).
3. Tap **Username** and enter your chosen username.
4. Tap **User Key / Password** and enter your password or secret key.
5. Tap **Register New Account** (if creating an account for the first time) or **Test Connection / Login**.
6. Ensure **Auto-Sync on Read/Close/Sleep** is enabled (checked by default).

---

## Lifecycle Sync Events

When `Auto-Sync` is enabled and the device is currently connected to Wi-Fi:
- **`onReaderReady`**: When opening a book, checks if a further reading position exists on another device and syncs forward.
- **`onCloseDocument`**: When closing a book, saves your current percentage and position to the cloud.
- **`onSuspend`**: When pressing the power button or closing your cover, saves your current position before sleep.
- **`onNetworkConnected`**: Automatically uploads current position when Wi-Fi becomes active while reading.
