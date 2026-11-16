# WATSafe

**WATSafe** is a cross-platform device protection application built with Flutter and native platform adapters for **macOS**, **Windows**, **iOS**, **Android**, and **Web**.

Desktop builds protect laptops against unauthorized physical movement while armed. Companion phones (iPhone and Android via the permanent HTTPS Home Screen web app or native mobile builds) pair **once**, receive real RFC 8291/8292 Web Push notifications even when locked, survive laptop/phone/relay restarts with offline shell caching, and open the exact event with the protected laptop’s recorded location in **Activity**.

---

## Current Capabilities Summary

| Capability | Status | Details |
|---|---|---|
| **3-Task Adaptive UI (`Home`, `Activity`, `Settings`)** | **Implemented & Tested** | Consistent Material 3 navigation (`NavigationRail` on desktop, `NavigationBar` on phone) with plain-language statuses (`Off`, `Arming`, `Protected`, `Monitoring paused`, `Alarm triggered`), one primary action per state, and accessible contrast. |
| **Permanent HTTPS Companion & Offline PWA Shell** | **Implemented & Tested** | Stable Web App Manifest (`id: '/companion'`, `start_url: '/companion?source=homescreen'`, `scope: '/'`, `display: 'standalone'`) and Service Worker (`/sw.js`) pre-caching the companion shell. Opening the Home Screen icon while offline or during proxy/tunnel outages always renders WATSafe (**Laptop offline** / **Connecting…** / **Service temporarily unavailable** with last-seen time and **Retry**)—never white proxy error pages (`HTTP 530` / Error `1033`). |
| **Durable One-Time Pairing & Auto-Reconnect** | **Implemented & Tested** | Device identities and pairing credentials persist securely (macOS Keychain + `0600` Application Support on desktop; mirrored `localStorage` + `IndexedDB` on PWA) and survive relay restarts via `PostgresRelayStore` (with durable VAPID keys in `watsafe_server_secrets`) or durable `FileRelayStore`. Reconnects automatically on app launch, foreground resume, and Wi-Fi/cellular switches; handles token rotation (`POST /v1/companion/token/refresh`) and `pushsubscriptionchange` renewal without re-pairing. |
| **Real RFC 8291/8292 Web Push & Event Deep-Links** | **Implemented & Tested** | Built-in pure-Dart VAPID (`ES256`) + `aes128gcm` Web Push sender plus verified `FCM` / `APNs` / webhook adapters. Unified delivery path for **Send test alert** and real alarms; marks **Notifications on** only after permission + subscription + backend registration succeed; deduplicates by `incidentId` and opens `/companion?event=<incidentId>`. |
| **Protected Device Location on Alarm** | **Implemented & Tested** | Non-blocking location capture (`CoreLocation` on macOS/iOS, Android `LocationManager`, Browser Geolocation) so location lookup never delays the local siren or initial phone alert; map preview, recorded timestamp, precision badge (`Precise` / `Approximate` / `Last known`), and **Open in Maps**. |
| **Central Alarm, PIN & First-Use Demo Controls** | **Implemented & Tested** | Generation-guarded state machine, immediate siren stop on verified 6+ digit PIN, PBKDF2-HMAC-SHA256 salted PIN storage, and development-only **Preview onboarding** & **Reset demo and restart onboarding** controls in **Settings -> Advanced**. |
| **Camera & Motion Sensor Detection** | **Implemented & Tested** | macOS `AVFoundation`, Windows Media Foundation + WinRT `Accelerometer`, Android Foreground Service motion sensors, iOS `CMMotionManager`, and Web camera scene-motion analysis (`64x48` 4x4 optical flow in volatile memory). |

---

## One-Time Setup: Giving the Phone Companion a Permanent HTTPS Address

### Why Temporary Quick Tunnels Caused White Error Pages After Restarts
Running an anonymous quick tunnel (`*.trycloudflare.com`, `*.lhr.life`, or free dynamic `ngrok`) creates a **brand-new random hostname** every time the launcher restarts. Because iOS Safari pins an installed Home Screen bookmark strictly to the domain it was installed from, closing and reopening the laptop launcher retired the previous `*.trycloudflare.com` tunnel—causing the old Home Screen icon to hit Cloudflare’s retired-tunnel page (`HTTP 530` / Error `1033` with a white page and *“Was this helpful?”*) instead of WATSafe.

To make Home Screen installation and pairing **true one-time setup steps**, point WATSafe at a permanent HTTPS origin once using either option below. *(Account sign-in to Render or Cloudflare is required once by you because cloud deployment requires your account authorization.)*

### Option 1 — Free Render Cloud Blueprint (`render.yaml`, Recommended)
1. In your Render dashboard, choose **New -> Blueprint** and connect `jonathannerd/WATSafe` (uses [`render.yaml`](render.yaml) and [`Dockerfile`](Dockerfile) to provision the HTTPS `watsafe-companion` service + managed PostgreSQL database so pairings, push subscriptions, and VAPID keys survive every redeploy).
2. Copy your permanent Render HTTPS URL (for example `https://watsafe-companion.onrender.com`).
3. Save it once on your Mac (persists to `~/.watsafe/relay_service.json` so every future launch reconnects automatically):
   ```bash
   ./scripts/run_watsafe.sh --save-permanent-url=https://watsafe-companion.onrender.com --save-only
   ```
   *(Or paste it directly inside **WATSafe -> Settings -> Phone companion address & migration** -> **Save**.)*

### Option 2 — Permanent Named Cloudflare Tunnel (Zero Cloud Hosting)
If you own a Cloudflare domain and create a Named Tunnel pointing to `http://127.0.0.1:8787`:
```bash
export WATSAFE_CLOUDFLARE_TUNNEL_TOKEN="<your-named-tunnel-token>"
./scripts/run_watsafe.sh --save-permanent-url=https://watsafe.yourdomain.com
```
Your local Mac relay stores pairings and VAPID keys durably in `~/.watsafe/relay/`, and the hostname never changes across restarts.

---

## Normal Everyday Launch (After One-Time Setup)

Once your permanent HTTPS URL is saved in `~/.watsafe/relay_service.json` (or [`config/relay_service.json`](config/relay_service.json)):

- **Double-click `WATSafe.app`** (`build/macos/Build/Products/Debug/WATSafe.app` or `Release/WATSafe.app`) — **no terminal required**. The Mac app automatically reconnects to your permanent HTTPS service, restores your paired iPhone, and sends a host presence heartbeat (`hostOnline: true`).
- **Or launch from source with one command:**
  ```bash
  ./scripts/run_watsafe.sh
  ```
  When a permanent HTTPS URL is saved, `run_watsafe.sh` connects directly to that permanent origin instead of spawning a temporary tunnel.

*(If you run `./scripts/run_watsafe.sh` before deploying a permanent URL, it still falls back to a temporary dev tunnel for quick local testing and prints a clear `[WATSafe] PERMANENT ADDRESS DEPENDENCY` notice in the terminal and pairing UI.)*

---

## One-Time Migration for Existing iPhone 13 Home Screen Installations

### Why One Final Home Screen Install & Pairing Is Required When Changing Domains
Apple WebKit strictly isolates Home Screen web apps, Service Workers, `CacheStorage`, `IndexedDB`/`localStorage` credentials, and `PushManager` Web Push subscriptions **per web origin** (`scheme + host + port`). Credentials and push subscriptions created under an old `https://random-words.trycloudflare.com` origin cannot be read by `https://watsafe-companion.onrender.com`.

Perform this migration **once**:
1. **Remove the old temporary bookmark on iPhone 13:** Touch and hold the old **WATSafe** icon on your iPhone Home Screen -> **Delete Bookmark**.
2. **Save your permanent HTTPS URL on your Mac:** Run `./scripts/run_watsafe.sh --save-permanent-url=https://<your-permanent-domain> --save-only` (or save it in **Settings -> Phone companion address & migration**), then open **WATSafe** and click **Pair your phone**.
3. **Install & pair once on the permanent address (`https://<your-permanent-domain>/companion`):**
   - Scan the QR code with the iPhone Camera app and tap **Connect to \<Your Mac\>**.
   - Tap **Copy setup code**, tap Safari **Share -> Add to Home Screen -> Add**, open the new **WATSafe** Home Screen icon, paste the 6-character setup code, and tap **Enable notifications -> Allow**.
4. **Done permanently:** From now on:
   - Closing and reopening WATSafe on your Mac or iPhone reconnects automatically.
   - If your Mac is closed or asleep, opening the iPhone Home Screen icon always opens WATSafe immediately (via the cached Service Worker shell) and displays **Laptop offline** with the last-seen time and a **Retry** button—never a white tunnel page.
   - Reopening WATSafe on your Mac automatically transitions the iPhone back to **Connected**.

---

## First-Use & Fresh-Start Testing

In debug/development builds, open **Settings -> Advanced** (`First-use & demo testing`):
- **Preview onboarding:** Inspects the welcome & PIN setup walkthrough without modifying saved PIN, paired phone, settings, or Activity history.
- **Reset demo and restart onboarding:** Stops active monitoring and silences siren audio immediately, revokes **only** this installation’s paired session and Web Push subscription on the relay, clears this device’s saved PIN and secure pairing credentials, and returns to `Welcome to WATSafe`.

---

## Verification Commands
```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
dart analyze tool/ backend/ lib/
flutter test
flutter build web
flutter build macos --debug
./scripts/run_watsafe.sh --check-only --no-tunnel
```

---

## Privacy & Security Invariants
- **Volatile Camera Frames & Local PINs:** Camera frames are analyzed strictly in memory and never saved or uploaded; PINs and PBKDF2 hashes never leave the device.
- **Secure Credential Persistence, Never in URLs or Logs:** Session tokens (`hostToken`, `companionToken`), VAPID private keys, and database URLs are stored in restricted/Keychain storage (`0600` on POSIX, macOS Keychain, and origin-scoped PWA storage) and are never placed in query strings, handoff URLs, plain device list files, client bundles, or logs.
- **Authentic-Origin Revocation Guard:** Saved pairings are cleared only on explicit user disconnect/reset or an authentic WATSafe `401` (`X-WATSafe-Companion: 1`), never on transient network errors or third-party proxy error pages.
- **Authenticated Coordinates & Private Lock-Screen Push Text:** Precise coordinates are returned only to authenticated session tokens; lock-screen Web Push payloads contain only the device name, plain alarm message, and opaque `incidentId`.
