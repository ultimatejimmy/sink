# Sink KOReader Plugin (`sink.koplugin`)

Non-intrusive, zero-password reading progress synchronization plugin for [KOReader](https://koreader.rocks/) on Kindle, Kobo, Android, and other e-readers.

---

## Key Features

- **Zero-Password Code Pairing**: Pair any e-reader in seconds by entering a 6-character code on your phone or PC browser. No tedious typing on e-ink keyboards!
- **Non-Intrusive Offline Safety**: Uses `NetworkMgr:isOnline()` for all lifecycle triggers (book opening, closing, device suspend, and Wi-Fi connect). Never triggers annoying Wi-Fi connection popups or battery drain when offline.
- **Silent Background Sync**: Background synchronization is completely quiet and suppresses all network toasts/errors so your reading flow is never interrupted.
- **Smart Progress Resolution**: Seamlessly merges progress between multiple devices, always respecting the latest and furthest reading position.

---

## Installation

1. Copy the `sink.koplugin` folder to your device's `koreader/plugins/` directory:
   - **Kindle**: `/mnt/us/koreader/plugins/sink.koplugin/`
   - **Kobo**: `.kobo/koreader/plugins/sink.koplugin/`
   - **Android**: `sdcard/koreader/plugins/sink.koplugin/`
2. Restart KOReader.

---

## Pairing & Setup

1. In KOReader, tap the top menu &rarr; **Tools** &rarr; **Sink** &rarr; **Pair Device (Phone/PC)**.
2. An e-ink friendly pairing screen will display your server link and a 6-character code (e.g. `K9X 2P4`).
3. Open the link on your phone or computer, enter the code, and tap **Connect E-Reader**.
4. KOReader will automatically detect the confirmation, save your credentials, and activate sync!
