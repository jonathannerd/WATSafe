# WATSafe Backend Relay & Web Push Companion (`backend/`)

The standalone WATSafe Relay Server (`backend/server.dart`, backed by `lib/relay/`) connects a protected device (`macOS`, `Windows`, or Browser) with a paired companion phone (`iPhone` Home Screen Web App, `Android` Chrome/PWA, or native mobile app) using short-lived, single-use HTTPS QR pairing links, RFC 8030 / RFC 8291 / RFC 8292 Web Push encryption, and session-scoped bearer tokens.

---

## 1. Security & Privacy Invariants

- **Strict Payload Sanitization:** Every write endpoint inspects incoming JSON keys and string values recursively and rejects (`400 PRIVACY_INVARIANT_VIOLATION`) any payload containing camera frames/images (`frame*`, `image*`, `rgba`, `nv12`, `data:image/*`), PIN material (`pin`, `pinHash`, `pbkdf2`, `salt*`), or database/provider credentials (`databaseUrl`, `aiven*`, `postgres://`, `privateKey`, `serviceAccount`).
- **Authenticated Location Access Only:** Protected device coordinates attached via `POST /v1/incidents/location` are stored strictly on the session's authenticated event record (`GET /v1/companion/alerts` and `GET /v1/companion/events/<incidentId>`). Lock-screen Web Push / APNs / FCM notification payloads contain **only** the protected device name, plain alarm message, and `incidentId` — never coordinates.
- **Zero Credentials in URLs:** Neither `companionToken` nor `hostToken` is ever placed in query strings. Moving from Mobile Safari into an isolated iOS Home Screen web app uses a short-lived, single-use 6-character setup code (`POST /v1/companion/handoff-code` -> `POST /v1/companion/claim-handoff`) that rotates the companion token on consumption.
- **Built-In RFC 8291 + RFC 8292 Web Push & Durable VAPID Keys:** Encrypts push payloads with `aes128gcm` (NIST P-256 ECDH + HKDF-SHA-256), signs VAPID `ES256` JWT headers directly in pure Dart, persists generated VAPID keys in `watsafe_server_secrets` (`PostgresRelayStore`) or local `vapid_keys.json` (`FileRelayStore`), and auto-revokes expired (`404` / `410`) push subscriptions.
- **Honest Storage Durability Telemetry:** `GET /v1/health` exposes `storageBackend`, `storageDurable`, and `storageDurabilityWarning` (`storageDurable: false` when running inside a cloud container such as Render without `DATABASE_URL` or `AIVEN_DATABASE_URL`) so an ephemeral container filesystem is never mistaken for permanent storage.

---

## 2. Cloud HTTPS Deployment with Durable PostgreSQL (`render.yaml` + `Dockerfile`)

Deployment files at the repository root (`Dockerfile` pinned to `dart:3.13.7-sdk` and `render.yaml`) prepare the HTTPS `watsafe-relay` service:

1. **Important storage behavior:**
   - `render.yaml` deploys the `watsafe-relay` Docker web service (providing a stable `https://<your-render-service>.onrender.com` certificate via `RENDER_EXTERNAL_URL`) and **prompts (`sync: false`) for environment secrets**. It **does not** provision PostgreSQL automatically.
   - **Do not** use Render’s expiring 30-day free PostgreSQL database or Render’s ephemeral container filesystem for permanent pairing.
   - The team deployment uses **Neon PostgreSQL** via `DATABASE_URL`. For your own deployment, supply a durable PostgreSQL connection URI in Render environment secrets (never in Git); Aiven is also supported.
2. **Deploy & set secrets in Render:**
   - In the Render Dashboard, choose **New -> Blueprint** and select `jonathannerd/WATSafe`.
   - Set `DATABASE_URL` to your PostgreSQL connection URI (for example, Neon). If using Aiven, you may set `AIVEN_DATABASE_URL` instead. The blueprint does not create the database.
   - Optionally set `AIVEN_CA_CERT` (PEM certificate string) if your URI uses `?sslmode=verify-full` or `?sslmode=verify-ca`.
3. **Verify the live HTTPS endpoint and database persistence across a restart/redeploy:**
   ```bash
   dart run tool/verify_deployment.dart --require-postgres --phase=before-restart https://<your-render-service>.onrender.com
   # Restart or redeploy watsafe-relay in Render, then run:
   dart run tool/verify_deployment.dart --require-postgres --phase=after-restart --save https://<your-render-service>.onrender.com
   ```
   Passing `--save` writes the verified permanent HTTPS origin to `~/.watsafe/relay_service.json` (and syncs to the macOS `WATSafe.app` sandbox container) so every future launch of `WATSafe.app` or `./scripts/run_watsafe.sh` reconnects automatically.

---

## 3. Local Development Launch

From the repository root:

```bash
./scripts/run_watsafe.sh
```

- If a permanent HTTPS URL has been saved in `~/.watsafe/relay_service.json`, `run_watsafe.sh` and `WATSafe.app` connect directly to that permanent origin.
- If `WATSAFE_CLOUDFLARE_TUNNEL_TOKEN` + `WATSAFE_PUBLIC_URL` are set, `run_watsafe.sh` starts the local relay (`~/.watsafe/relay/`) behind your permanent Named Cloudflare Tunnel.
- Otherwise, `run_watsafe.sh` starts the local relay with a temporary development tunnel and prints a notice explaining one-time permanent setup.

---

## 4. Environment Variables Reference

| Variable | Purpose |
| :--- | :--- |
| `PORT` / `WATSAFE_BIND_HOST` | Listen port (default `8787`) and bind address (default `0.0.0.0`) |
| `WATSAFE_PUBLIC_URL` | Permanent public HTTPS base URL encoded into QR pairing links (auto-detected on Render via `RENDER_EXTERNAL_URL`) |
| `AIVEN_DATABASE_URL` / `DATABASE_URL` | PostgreSQL connection URI (Neon or another supported provider) (`postgres://...`, environment secret only—never committed to Git). Required in cloud containers for durable storage. The legacy adapter label `storageBackend: aiven_postgres` can also represent Neon; check `storageDurable: true`. |
| `AIVEN_CA_CERT` / `AIVEN_CA_CERT_PATH` / `PGSSLROOTCERT` | Optional Aiven CA certificate (inline PEM string or file path) for `SslMode.verifyFull` |
| `WATSAFE_DATA_DIR` | Directory for local host `FileRelayStore` when running on a personal Mac/PC (`~/.watsafe/relay` by default; ephemeral inside cloud containers unless `WATSAFE_PERSISTENT_VOLUME=true`) |
| `VAPID_PUBLIC_KEY` + `VAPID_PRIVATE_KEY` | Optional explicit NIST P-256 VAPID keypair (base64url); when omitted, WATSafe generates once and persists durably in `watsafe_server_secrets` (PostgreSQL) or local `vapid_keys.json` |
| `VAPID_SUBJECT` | Contact URI for VAPID JWT `sub` claim (use a valid public contact URI or the public HTTPS relay origin; do not use a `.local` subject) |
| `FCM_PROJECT_ID` + `FCM_BEARER_TOKEN` / `FCM_SERVER_KEY` | Optional Firebase Cloud Messaging credentials for native Android/iOS push tokens |
| `APNS_BUNDLE_ID` + `APNS_AUTH_TOKEN` | Optional Apple Push Notification service HTTP/2 credentials for native iOS builds |
| `WATSAFE_PUSH_WEBHOOK_URL` | Optional external push gateway URL (verified on startup) |

---

## 5. Key Endpoints

| Endpoint | Auth | Description |
| :--- | :--- | :--- |
| `GET /`, `GET /pair`, `GET /companion` | Public HTML | Permanent-shell iPhone & Android Web Companion PWA (`X-WATSafe-Companion: 1`) |
| `GET /manifest.webmanifest`, `GET /sw.js`, `GET /icons/*` | Public PWA | Stable Web App Manifest (`id: '/companion'`, `start_url: '/companion?source=homescreen'`, `scope: '/'`, `standalone`), icons, and offline-caching Service Worker |
| `GET /v1/health` | Public JSON | Readiness check, `storageBackend`, `storageDurable`, `storageDurabilityWarning`, `vapidPublicKey`, and `permanentHttpsOrigin` |
| `POST /v1/pairing/initiate` | Optional `Bearer <hostToken>` | Generates a 5-minute single-use code and HTTPS `/pair?code=...` QR URL |
| `POST /v1/host/heartbeat` | `Bearer <hostToken>` | Marks protected laptop online (`hostOnline: true`, `hostLastSeenAtUtc`) and returns active paired devices |
| `POST /v1/host/offline` | `Bearer <hostToken>` | Marks protected laptop offline on clean app exit while keeping pairing intact |
| `GET /v1/pairing/lookup?code=...` | Rate-limited | Non-consuming code preview returning `hostDisplayName` and `vapidPublicKey` |
| `POST /v1/pairing/complete` | Rate-limited `pairingCode` | Consumes single-use code, deduplicates by `deviceId`, and returns `companionToken` |
| `POST /v1/companion/handoff-code` | `Bearer <companionToken>` | Mints 10-minute single-use 6-char code to move pairing from iOS Safari into Home Screen web app |
| `POST /v1/companion/claim-handoff` | Rate-limited `handoffCode` | Transfers existing paired bond into Home Screen app and immediately invalidates the browser token |
| `POST /v1/companion/token/refresh` | `Bearer <companionToken>` | Rotates `companionToken` in-place with a 60-second grace window on the previous token |
| `POST /v1/companion/push-subscription` | `Bearer <companionToken>` | Validates & stores RFC 8291 Web Push subscription (`endpoint`, `p256dh`, `auth`) |
| `DELETE /v1/companion/push-subscription` | `Bearer <companionToken>` | Removes Web Push subscription and marks notifications disabled |
| `POST /v1/companion/status` | `Bearer <companionToken>` | Updates 5-state readiness and returns `hostOnline` + `hostLastSeenAtUtc` |
| `POST /v1/companion/test-alert` | `Bearer <companionToken>` | Dispatches immediate or delayed (`delaySeconds` `0..10`) real Web Push test alert |
| `POST /v1/companion/disconnect` | `Bearer <companionToken>` | Revokes companion bond from the phone |
| `POST /v1/pairing/session/revoke` | `Bearer <hostToken>` | Revokes only this host installation's session, bonds, push registrations, and alerts |
| `GET /v1/pairing/devices` | `Bearer <hostToken>` | Lists paired phones and accurate notification readiness for the host |
| `DELETE /v1/pairing/devices/<id>` | `Bearer <hostToken>` | Disconnects a phone and revokes its `companionToken` |
| `POST /v1/incidents:report` | `Bearer <hostToken>` | Records real or test alarm (`incidentId` deduplicated) and dispatches real Web Push |
| `POST /v1/incidents/location` | `Bearer <hostToken>` | Attaches asynchronous device location to an existing `incidentId` |
| `GET /v1/companion/alerts?afterSeq=<n>` | `Bearer <companionToken>` | Streams new and location-updated session alerts plus `hostOnline` / `hostLastSeenAtUtc` |
| `GET /v1/companion/events/<incidentId>` | `Bearer <companionToken \| hostToken>` | Authenticated single-event + location lookup |
