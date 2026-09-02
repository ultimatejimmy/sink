# Sink UI/UX Design System & Style Guide

This style guide defines conventions, typography, e-ink guidelines, and user experience rules for the **Sink** KOReader plugin and Cloudflare Worker backend.

---

## 1. Punctuation & Typography

### Forward Slashes ("/")
- **Rule**: **Zero spaces around forward slashes** for compound words, choices, and option pairs.
  - Correct: `Phone/PC`, `Read/Close/Sleep`, `Filename/Binary`, `Unlink/Clear`, `Kindle/KOReader`
  - Incorrect: `Phone / PC`, `Read / Close / Sleep`, `Filename / Binary`, `Unlink / Clear`

### Capitalization
- **Title Case** for:
  - Main menu entries (`Pair Device (Phone/PC)`, `Sync Progress Now`, `Paired Devices`)
  - Dialog titles (`Pair Device (Sink)`, `Cloud Library`, `Check for Updates`)
  - Buttons (`Connect E-Reader →`, `Cancel`, `Set Server URL`, `Update Backend Now`)
- **Sentence case** for:
  - Explanatory subtitles and descriptions (`Scan with your phone to pair instantly:`, `No remote progress found for this book.`)
  - Status messages and error alerts

### Ellipses ("...")
- Use the standard three dots `...` directly appended to the verb without preceding whitespace for actions currently in-flight:
  - Correct: `Connecting...`, `Syncing...`, `Rebuilding...`
  - Incorrect: `Connecting ...`, `Syncing …`

---

## 2. E-Ink Display & Touch UI Principles

### High-Contrast Monochrome
- Avoid subtle gray shades for critical text. High-contrast pure black (`#000000`) on white (`#FFFFFF`) or pure white on dark backgrounds ensures clarity on Carta and Pearl E-Ink panels.
- Font sizes should always scale through `Font:getFace("infofont")` or `Screen:scaleBySize()` to adapt gracefully across 212 DPI to 300+ DPI displays.

### QR Code Framing
- Any QR code displayed on e-ink MUST be rendered on a solid white container with quiet-zone padding of at least 6px (`Size.padding.default`). This ensures camera autofocus can identify and scan the QR code without distortion from border elements.

### Verification & Pairing Codes
- Always format 6-character pairing codes with spaced grouping for instant e-ink readability:
  - Display: `K 9 X   2 P 4`
  - Canonical stored value: `K9X2P4` (uppercase, no spaces).

---

## 3. Non-Intrusive Background Syncing

1. **Silent Failures in Background**:
   - Automated triggers (`onReaderReady`, `onCloseDocument`, `onSuspend`, `onResume`, `onNetworkConnected`) must NEVER trigger blocking popups, modal alerts, or Wi-Fi dialogs if the network is down or slow.
   - Suppress background exceptions and log via `logger.warn` or `logger.info`.

2. **Explicit User Feedback**:
   - When a user deliberately taps an action button (e.g., "Sync Progress Now", "Pair Device", "Test Connection"), provide immediate, visible feedback (`Notification` or `InfoMessage`).

---

## 4. Internationalization & Strings

- Every user-visible string must be wrapped using the localization function `_("...")`.
- Do not concatenate dynamic strings directly within translatable sentences. Use format specifiers (`string.format(_("Connected as: %s"), username)`).
- Keep source keys in `languages/en.po` as the canonical master copy.
