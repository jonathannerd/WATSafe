# WATSafe

**WATSafe** is a cross-platform device protection application built with Flutter and native platform adapters for **macOS**, **Windows**, **iOS**, **Android**, and **Web**.

Desktop builds protect laptops against unauthorized physical movement while armed. Companion phones (iPhone and Android via the guided HTTPS Home Screen web app or native mobile builds) pair by scanning one QR code, receive real RFC 8291/8292 Web Push notifications even when locked, and open the exact event with the protected laptop’s recorded location in **Activity**.

---

## Current Capabilities Summary

| Capability | Status | Details |
|---|---|---|
| **3-Task Adaptive UI (`Home`, `Activity`, `Settings`)** | **Implemented & Tested** | Consistent Material 3 navigation (`NavigationRail` on desktop, `NavigationBar` on phone) with plain-language statuses (`Off`, `Arming`, `Protected`, `Monitoring paused`, `Alarm triggered`), one primary action per state, and accessible contrast. |
| **Guided iPhone & Android HTTPS Pairing + PWA** | **Implemented & Tested** | Tapping **Pair your phone** displays an HTTPS QR code (`/pair?code=...`) and 6-character fallback code. Serves `/manifest.webmanifest`, `apple-touch-icon` (`180x180`), `192x192` & `512x512` icons, and `/sw.js`. Separately checks HTTPS, iOS Home Screen standalone mode, notification permission, `PushManager` subscription, and backend registration—guiding Safari -> Home Screen handoff without ever putting tokens in URLs or showing dead notification buttons. |
| **Real RFC 8291/8292 Web Push & Event Deep-Links** | **Implemented & Tested** | Built-in pure-Dart VAPID (`ES256`) + `aes128gcm` Web Push sender plus verified `FCM` / `APNs` / webhook adapters. Unified delivery path for **Send test alert** (instant or 5-second lock-phone test) and real alarms; marks **Notifications on** only after permission + subscription + backend registration succeed; deduplicates by `incidentId` and opens the exact event in **Activity**. |
| **Single-Command Dev Launch & Zero-Terminal App Startup** | **Implemented & Tested** | Opening `WATSafe.app` directly works with zero terminals (reconnecting automatically to a configured HTTPS relay or running an embedded loopback relay). `./scripts/run_watsafe.sh` starts the local relay + valid-certificate HTTPS tunnel + macOS app in one command, verifies TLS `/v1/health`, and cleans up child processes on exit. |
| **Protected Device Location on Alarm** | **Implemented & Tested** | Non-blocking location capture (`CoreLocation` on macOS/iOS, Android `LocationManager`, Browser Geolocation) so location lookup never delays the local siren or initial phone alert; map preview, recorded timestamp, precision badge (`Precise` / `Approximate` / `Last known`), and **Open in Maps**. |
| **Central Alarm, PIN & First-Use Demo Controls** | **Implemented & Tested** | Generation-guarded state machine, immediate siren stop on verified 6+ digit PIN, PBKDF2-HMAC-SHA256 salted PIN storage, and development-only **Preview onboarding** & **Reset demo and restart onboarding** controls in **Settings -> Advanced**. |
| **Camera & Motion Sensor Detection** | **Implemented & Tested** | macOS `AVFoundation`, Windows Media Foundation + WinRT `Accelerometer`, Android Foreground Service motion sensors, iOS `CMMotionManager`, and Web camera scene-motion analysis (`64x48` 4x4 optical flow in volatile memory). |

---

## Launching WATSafe Easily

### Option A — Single Command for Local Mac + Real iPhone HTTPS Testing (Recommended for Demos)
From the repository root, run **one command**:
```bash
./scripts/run_watsafe.sh
```
What this does automatically:
1. Picks port `8787` (or the next free port if occupied) and starts the local WATSafe relay with persistent VAPID Web Push keys (`.watsafe-runtime/vapid_keys.json`).
2. Opens a valid-certificate public HTTPS tunnel (`cloudflared`, `ngrok`, or built-in macOS `ssh` via `localhost.run` — no account or payment required) and verifies `/v1/health` over TLS.
3. Passes the verified `https://...` origin to both the QR generator and `flutter run -d macos` (`WATSAFE_API_URL`) so scanning the laptop QR on an iPhone 13 opens an HTTPS URL with a trusted certificate.
4. Stops all child processes cleanly when you exit or press `Ctrl+C`.

Useful launcher flags:
```bash
./scripts/run_watsafe.sh --check-only   # Verify relay + public HTTPS tunnel readiness and exit cleanly
./scripts/run_watsafe.sh --relay-only   # Run relay + HTTPS tunnel only (for pairing with a prebuilt WATSafe.app)
```

### Option B — Normal App Launch (No Terminals Required)
Once built (`flutter build macos`), double-clicking `build/macos/Build/Products/Debug/WATSafe.app` (or `Release/WATSafe.app`) works immediately without opening any terminal:
- If built with `--dart-define=WATSAFE_API_URL=https://<your-cloud-relay>` (or previously paired against a cloud HTTPS relay), `WATSafe.app` reconnects automatically on launch.
- If no external relay is configured, `WATSafe.app` automatically starts an embedded local relay in-process. (Note: Apple requires a valid HTTPS origin—via `./scripts/run_watsafe.sh` or a deployed cloud relay—for iPhone Home Screen Web Push.)
- Free-tier persistent HTTPS deployment files (`Dockerfile`, `render.yaml`, and `tool/generate_vapid_keys.dart`) are ready in [`backend/README.md`](backend/README.md).

---

## Step-by-Step iPhone 13 Companion Setup

Apple requires iOS web apps to be served over **HTTPS** and opened from the **Home Screen** before system notifications and Web Push are exposed (WebKit Web Push policy for iOS 16.4+). WATSafe detects every requirement separately and guides you step by step:

1. Launch WATSafe with `./scripts/run_watsafe.sh` (or against your HTTPS cloud relay) and click **Pair your phone** on your Mac.
2. Scan the QR code with the **iPhone Camera** app and tap **Connect to \<Your Mac\>**.
3. On iPhone Safari, WATSafe detects that Home Screen installation is needed next:
   - Tap **Copy setup code** (a short 6-character single-use handoff code; no tokens are placed in the URL).
   - Tap the Safari **Share** button -> **Add to Home Screen** -> **Add**.
4. Open the **WATSafe** icon from your iPhone **Home Screen** and enter the 6-character code to link your paired session inside the installed app.
5. Tap **Enable notifications** and tap **Allow** on the iOS system prompt. Both your iPhone and Mac will update to **Notifications on** only after permission, `PushManager` subscription, and backend registration all succeed.
6. Tap **Test in 5s (lock phone now)**, lock your iPhone, verify the lock-screen notification arrives, and tap it to open the exact event in **Activity**.

---

## First-Use & Fresh-Start Testing

### Why Relaunching Keeps Your Data
Relaunching `WATSafe.app` or pressing `R` (hot restart) in `flutter run` intentionally preserves your saved PIN, paired phone session, device name, settings, and **Activity** history so protection settings survive normal restarts.

### Resetting to a Clean First Launch (Mac + Phone)
In debug/development builds, open **Settings -> Advanced** (`First-use & demo testing`):
- **Preview onboarding:** Opens the welcome & PIN setup walkthrough immediately while keeping your saved PIN, paired phone, settings, and Activity history intact. Click **Exit preview** at the top to return.
- **Reset demo and restart onboarding:** After confirmation, stops any active monitoring and silences siren audio immediately, revokes **only** this installation’s paired phone session and Web Push subscription on the relay, clears this device’s saved PIN, resets settings and Activity history, and returns immediately to `Welcome to WATSafe`.
- **Resetting on iPhone:** Delete the **WATSafe** icon from the iPhone Home Screen (touch and hold -> **Remove App** -> **Delete Bookmark**).

### Resetting OS & Browser Permissions Separately
App resets cannot revoke OS-level privacy grants. To re-test first-time OS permission prompts:
- **macOS Camera / Location / Notifications:** Open **System Settings -> Privacy & Security** (`Camera`, `Location Services`, or `Notifications`) and toggle **WATSafe**, or reset Camera permission in Terminal with:
  ```bash
  tccutil reset Camera dev.watsafe.temp.watsafe
  ```
- **iPhone Web App Notifications:** Open **iOS Settings -> Notifications -> WATSafe** and toggle **Allow Notifications** off (or delete and re-add the Home Screen icon).
- **Desktop / Android Browser Permissions:** Tap the site lock/tune icon in the address bar -> **Permissions** -> **Reset permissions**.

---

## Verification Commands
```bash
flutter pub get
flutter analyze
flutter test
flutter build web
flutter build macos --debug
./scripts/run_watsafe.sh --check-only
```

---

## Privacy & Security Invariants
- **Volatile Camera Frames & Local PINs:** Camera frames are analyzed strictly in memory and never saved or uploaded; PINs and PBKDF2 hashes never leave the device.
- **No Credentials in URLs or Logs:** Session tokens (`hostToken`, `companionToken`), VAPID private keys, and database URLs are never placed in query strings, handoff URLs, client bundles, or logs.
- **Authenticated Coordinates & Private Lock-Screen Push Text:** Precise coordinates are returned only to authenticated session tokens; lock-screen Web Push payloads contain only the device name and plain alarm message.
