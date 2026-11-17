# WATSafe

**WATSafe** is a cross-platform device protection application built with Flutter (`3.47.9` / Dart `3.13.7`) and native platform adapters for **macOS**, **Windows**, **iOS**, **Android**, and **Web**.

Desktop builds protect laptops against unauthorized physical movement while armed. Companion phones (iPhone and Android via the permanent HTTPS Home Screen web app or native mobile builds) pair **once**, receive real RFC 8291/8292 Web Push notifications even when locked, survive laptop/phone/relay restarts with offline shell caching, and open the exact event with the protected laptop’s recorded location in **Activity**.

---

## Current Capabilities Summary

| Capability | Status | Details |
|---|---|---|
| **4-Destination Adaptive UI (`Home`, `Devices`, `Activity`, `Settings`)** | **Implemented & Tested** | Consistent Material 3 navigation (`NavigationRail` on desktop, `NavigationBar` on phone, and matching 4-tab Companion PWA) with plain-language statuses (`Off`, `Arming`, `Protected`, `Movement detected — checking…`, `Monitoring paused`, `Alarm triggered`), one primary action per state, and accessible contrast. |
| **Permanent HTTPS Companion & Offline PWA Shell** | **Implemented & Tested** | Stable Web App Manifest (`id: '/companion'`, `start_url: '/companion?source=homescreen'`, `scope: '/'`, `display: 'standalone'`) and Service Worker (`/sw.js`) pre-caching the companion shell. Opening the Home Screen icon while offline or during proxy/tunnel outages always renders WATSafe (**Laptop offline** / **Connecting…** / **Service temporarily unavailable** with last-seen time and **Retry**)—never white proxy error pages (`HTTP 530` / Error `1033`). |
| **Durable One-Time Pairing & Auto-Reconnect** | **Implemented & Tested** | Device identities and pairing credentials persist securely (macOS Keychain + `0600` Application Support on desktop; mirrored `localStorage` + `IndexedDB` on PWA) and survive relay restarts via `PostgresRelayStore` (`DATABASE_URL` / `AIVEN_DATABASE_URL`, with durable VAPID keys in `watsafe_server_secrets`) or local `FileRelayStore` (`~/.watsafe/relay`). Reconnects automatically on app launch, foreground resume, and Wi-Fi/cellular switches; handles token rotation (`POST /v1/companion/token/refresh`) and `pushsubscriptionchange` renewal without re-pairing. |
| **Real RFC 8291/8292 Web Push & Incident Map Routing** | **Implemented & Tested** | Built-in pure-Dart VAPID (`ES256`) + `aes128gcm` Web Push sender plus verified `FCM` / `APNs` / webhook adapters. Unified delivery path for **Send test alert** and real alarms; Service Worker receipt acknowledgements (`/v1/companion/events/<id>/ack`); tapping an alarm notification opens the exact incident and affected device with its map immediately visible. |
| **Devices Map & Bounded Post-Alarm Location Tracking** | **Implemented & Tested** | Protected-device location strictly attributed to the protected device (`CoreLocation` on macOS/iOS, Android `LocationManager`, Browser Geolocation)—never delaying the local siren or initial push alert. Interactive **Devices** & **Activity** maps (OpenStreetMap / OpenFreeMap + MapLibre GL JS with offline vector graticule fallback), accuracy circles, **Center on device**, **Open in Maps**, distinct **Alarm-time location** vs. **Latest known location**, bounded 15s post-alarm updates (max 15m / 40 samples, stopping immediately on PIN disarm), jitter & teleport filtering, session-isolated `403` auth, 7-day retention pruning, and **Delete stored location history**. |
| **Theft Ego-Motion Detection & False-Alarm Reduction** | **Implemented & Tested** | Separates rigid camera ego-motion (lift, tilt, carry, slow slide via 4-frame drift window) from passersby, radial looming/leaning, brief hand passes, room lighting/shadow shifts, and seated occupancy; treats AC power-cable unplug strictly as weak supporting corroboration; brief **Movement detected — checking…** stage for borderline camera-only motion; plain-language presets (**Fewer false alarms**, **Balanced**, **Higher sensitivity**), silent **Guided protection test**, and non-frame numerical diagnostics in **Settings -> Advanced**. |
| **Central Alarm, PIN & Future Owner Face-Verify Design** | **Implemented & Tested** | Generation-guarded state machine, immediate siren & location-timer stop on verified 6+ digit PIN, PBKDF2-HMAC-SHA256 salted PIN storage, development-only **Preview onboarding** & **Reset demo**, and architecture design doc for optional future local owner face verification ([`docs/owner-face-recognition-design.md`](docs/owner-face-recognition-design.md), disabled by default). |

---

## One-Time Setup: Permanent HTTPS Companion & Durable Aiven PostgreSQL Storage

### Why Temporary Quick Tunnels Caused White Error Pages After Restarts
Running an anonymous quick tunnel (`*.trycloudflare.com`, `*.lhr.life`, or dynamic `ngrok`) creates a **new random hostname** every time the launcher restarts. Because iOS Safari pins an installed Home Screen bookmark strictly to the domain it was installed from, closing and reopening the laptop launcher retired the previous `*.trycloudflare.com` tunnel—causing the old Home Screen icon to hit Cloudflare’s retired-tunnel page (`HTTP 530` / Error `1033` with a white page and *“Was this helpful?”*) instead of WATSafe.

### Important Storage Rules for Cloud Deployments
- [`render.yaml`](render.yaml) deploys the `watsafe-relay` Docker web service (providing a permanent `https://<your-render-service>.onrender.com` origin via Let’s Encrypt) and **prompts (`sync: false`) for environment secrets**. It **does not** provision PostgreSQL automatically.
- **Do not** use Render’s free PostgreSQL tier (it expires and deletes data after 30 days) or Render’s container filesystem (ephemeral: wiped on every redeploy and container spin-down) as permanent storage. `/v1/health` explicitly reports `storageDurable: false` if a cloud container runs without PostgreSQL.
- **Use our existing Aiven PostgreSQL (`AIVEN_DATABASE_URL`)** for permanent cloud storage, keeping credentials strictly in Render environment secrets (never in Git). When `AIVEN_DATABASE_URL` is set, WATSafe stores pairing sessions (`watsafe_pairing_sessions`), paired phone bonds & Web Push subscriptions (`watsafe_companion_bonds`), incidents (`watsafe_session_alerts`), and VAPID keys (`watsafe_server_secrets`) durably in Aiven PostgreSQL across restarts and redeployments.

### Option 1 — Render HTTPS Web Service + Existing Aiven PostgreSQL (Recommended)
1. In the [Render Dashboard](https://dashboard.render.com), click **New -> Blueprint** and select `jonathannerd/WATSafe` ([`render.yaml`](render.yaml) + [`Dockerfile`](Dockerfile)).
2. When prompted for `sync: false` environment secrets:
   - Set **`AIVEN_DATABASE_URL`** to our Aiven PostgreSQL Service URI (`postgres://avnadmin:<password>@<project>.aivencloud.com:<port>/defaultdb?sslmode=require`).
   - *(Optional)* Set **`AIVEN_CA_CERT`** (PEM text) only if your URI specifies `?sslmode=verify-full` or `?sslmode=verify-ca`.
   - *(Optional)* Leave `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY` blank to let WATSafe generate and persist them automatically in `watsafe_server_secrets`, or supply explicit keys from `dart run tool/generate_vapid_keys.dart`.
3. **Verify the live HTTPS endpoint and persistence across a relay restart/redeploy before calling setup complete:**
   ```bash
   # Step A: Verify HTTPS, PWA manifest/service worker, durable Aiven storage, and record a test bond + push subscription
   dart run tool/verify_deployment.dart --require-postgres --phase=before-restart https://<your-render-service>.onrender.com

   # Step B: Restart or redeploy `watsafe-relay` in Render, then verify VAPID keys + pairing + push subscription survived
   # and save the verified URL locally for WATSafe.app and ./scripts/run_watsafe.sh:
   dart run tool/verify_deployment.dart --require-postgres --phase=after-restart --save https://<your-render-service>.onrender.com
   ```

### Option 2 — Permanent Named Cloudflare Tunnel + Local Mac Relay
If you route a permanent Cloudflare hostname (`https://watsafe.<your-domain>`) to `http://127.0.0.1:8787`:
```bash
export WATSAFE_CLOUDFLARE_TUNNEL_TOKEN="<your-named-tunnel-token>"
./scripts/run_watsafe.sh --save-permanent-url=https://watsafe.<your-domain>
```
On your Mac, the local relay stores pairings, push subscriptions, and VAPID keys durably on disk in `~/.watsafe/relay/` (or in Aiven PostgreSQL if `AIVEN_DATABASE_URL` is exported in your shell environment).

---

## Normal Everyday Launch (After One-Time Setup)

Once your verified permanent HTTPS URL is saved (stored in `~/.watsafe/relay_service.json`, synced to the macOS `WATSafe.app` sandbox container, and persisted in `ProtectionSettings`):

- **Open `WATSafe.app` directly** (`build/macos/Build/Products/Debug/WATSafe.app` or `Release/WATSafe.app`) — **no terminal required**. The desktop app remembers the permanent HTTPS endpoint, reconnects automatically, restores your paired phone, and sends host presence heartbeats (`POST /v1/host/heartbeat`) plus clean sign-off (`POST /v1/host/offline`) on exit.
- **Or launch from source with one command:**
  ```bash
  ./scripts/run_watsafe.sh
  ```
  When a permanent HTTPS URL is saved, `run_watsafe.sh` connects directly to that permanent origin instead of spawning a temporary tunnel.

---

## One-Time Migration & Physical iPhone Test Checklist

### One-Time Migration from an Old Temporary Tunnel Bookmark
Apple WebKit isolates Home Screen web apps, Service Workers, `IndexedDB`/`localStorage`, and `PushManager` subscriptions per origin (`scheme + host + port`). When moving from an old `*.trycloudflare.com` tunnel to your verified permanent `https://<your-render-service>.onrender.com` origin:
1. Delete any old temporary **WATSafe** bookmark from your iPhone Home Screen.
2. Open **WATSafe** on your Mac -> **Pair your phone**, scan the QR code in Safari (`https://<your-render-service>.onrender.com/pair?...`), and tap **Connect to \<Your Mac\>**.
3. Tap **Copy setup code**, tap Safari **Share -> Add to Home Screen -> Add**, open the new **WATSafe** Home Screen icon, paste the 6-character setup code, and tap **Enable notifications -> Allow**.

### Physical iPhone Verification Checklist
1. **Close and reopen the desktop app:** Quit `WATSafe.app` on your Mac -> confirm the installed iPhone app stays paired and switches to **Laptop offline** (with last-seen time). Reopen `WATSafe.app` normally -> confirm both Mac and iPhone return to **Connected** automatically without scanning a QR code.
2. **Close and reopen the installed phone app:** Swipe away the **WATSafe** Home Screen app on iPhone and reopen it -> confirm it opens directly in standalone mode as **Connected** with **Notifications on** retained.
3. **Restart the relay:** Trigger a restart/redeploy of `watsafe-relay` on Render -> confirm the iPhone shows **Connecting…** / **Service temporarily unavailable** (never a white error page) and automatically returns to **Connected** with its push subscription and VAPID key intact.
4. **Switch Wi-Fi to cellular:** Turn off Wi-Fi on iPhone so it switches to cellular data -> confirm the installed Home Screen app stays **Connected** and tap **Send test alert** to verify delivery over cellular.
5. **Receive a locked-screen alarm notification:** Tap **Send test alert (5s — lock phone now)** or arm the Mac and trigger an alarm while the iPhone screen is locked -> confirm the lock-screen push notification arrives (device name + plain message only, no coordinates) and tapping it opens the exact event with location in **Activity**.

---

## First-Use & Fresh-Start Testing

In debug/development builds, open **Settings -> Advanced** (`First-use & demo testing`):
- **Preview onboarding:** Inspects the welcome & PIN setup walkthrough without modifying saved PIN, paired phone, settings, or Activity history.
- **Reset demo and restart onboarding:** Stops active monitoring and silences siren audio immediately, revokes **only** this installation’s paired session and Web Push subscription on the relay, clears this device’s saved PIN and secure pairing credentials (while keeping your configured permanent HTTPS server URL), and returns to `Welcome to WATSafe`.

---

## Verification Commands
```bash
flutter pub get
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
- **Secrets Strictly Outside Git:** `AIVEN_DATABASE_URL`, `AIVEN_CA_CERT`, `VAPID_PRIVATE_KEY`, and tunnel tokens live exclusively in environment secrets or restricted local `0600`/Keychain storage—never in Git, query strings, client bundles, or logs.
- **Authentic-Origin Revocation Guard:** Saved pairings are cleared only on explicit user disconnect/reset or an authentic WATSafe `401` (`X-WATSafe-Companion: 1`), never on transient network errors or third-party proxy error pages.
- **Authenticated Session-Isolated Coordinates, 7-Day Retention & Private Lock-Screen Push Text:** Device locations and post-alarm trails require authenticated session tokens (`403` on cross-session/device ID queries), expire automatically after 7 days (or immediately via **Delete stored location history**), never plot missing coordinates at `(0, 0)`, and never appear in lock-screen Web Push text, URLs, or routine logs.
