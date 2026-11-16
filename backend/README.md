# WATSafe Backend Relay & Web Push Companion (`backend/`)

The standalone WATSafe Relay Server (`backend/server.dart`, backed by `lib/relay/`) connects a protected device (`macOS`, `Windows`, or Browser) with a paired companion phone (`iPhone` Home Screen Web App, `Android` Chrome/PWA, or native mobile app) using short-lived, single-use HTTPS QR pairing links, RFC 8030 / RFC 8291 / RFC 8292 Web Push encryption, and session-scoped bearer tokens.

---

## 1. Security & Privacy Invariants

- **Strict Payload Sanitization:** Every write endpoint inspects incoming JSON keys and string values recursively and rejects (`400 PRIVACY_INVARIANT_VIOLATION`) any payload containing camera frames/images (`frame*`, `image*`, `rgba`, `nv12`, `data:image/*`), PIN material (`pin`, `pinHash`, `pbkdf2`, `salt*`), or database/provider credentials (`databaseUrl`, `aiven*`, `postgres://`, `privateKey`, `serviceAccount`).
- **Authenticated Location Access Only:** Protected device coordinates attached via `POST /v1/incidents/location` are stored strictly on the session's authenticated event record (`GET /v1/companion/alerts` and `GET /v1/companion/events/<incidentId>`). Lock-screen Web Push / APNs / FCM notification payloads contain **only** the protected device name, plain alarm message, and `incidentId` — never coordinates.
- **Zero Credentials in URLs:** Neither `companionToken` nor `hostToken` is ever placed in query strings. Moving from Mobile Safari into an isolated iOS Home Screen web app uses a short-lived, single-use 6-character setup code (`POST /v1/companion/handoff-code` -> `POST /v1/companion/claim-handoff`) that rotates the companion token on consumption.
- **Built-In RFC 8291 + RFC 8292 Web Push:** Encrypts push payloads with `aes128gcm` (NIST P-256 ECDH + HKDF-SHA-256) and signs VAPID `ES256` JWT headers directly in pure Dart, auto-revoking expired (`404` / `410`) push subscriptions.
- **Verified Webhook Adapter:** When `WATSAFE_PUSH_WEBHOOK_URL` is configured, `verifyConfiguredSenders()` probes reachability on startup and reports `webhookSenderVerified` on `/v1/health` rather than assuming an unverified webhook works.

---

## 2. Single-Command Local HTTPS Launch

From the repository root, start the relay, a valid-certificate public HTTPS tunnel (`cloudflared` -> `ngrok` -> built-in `ssh localhost.run`), health verification, and the WATSafe desktop app with one command:

```bash
./scripts/run_watsafe.sh
```

Or when opening `WATSafe.app` directly without a terminal, `LocalRelaySupervisor` automatically connects to your configured HTTPS relay or starts an embedded local relay in-process.

---

## 3. Free Persistent Cloud HTTPS Deployment (Zero Paid Services)

Deployment files are ready at the repository root (`Dockerfile` and `render.yaml` on the **Free** plan):

1. Generate a persistent VAPID keypair locally (keys stay out of Git):
   ```bash
   dart run tool/generate_vapid_keys.dart
   ```
2. On [Render](https://dashboard.render.com) (Free tier, automatic Let's Encrypt HTTPS certificate), click **New -> Blueprint**, select `jonathannerd/WATSafe`, and paste `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY` (plus optional `AIVEN_DATABASE_URL`) into the environment prompt.
3. Build or run WATSafe once with your HTTPS relay URL baked in:
   ```bash
   flutter build macos --dart-define=WATSAFE_API_URL=https://watsafe-relay.onrender.com
   ```
   Opening `WATSafe.app` then connects directly over HTTPS every time with zero local terminals or tunnels required.

---

## 4. Environment Variables Reference

| Variable | Purpose |
| :--- | :--- |
| `PORT` / `WATSAFE_BIND_HOST` | Listen port (default `8787`) and bind address (default `0.0.0.0`) |
| `WATSAFE_PUBLIC_URL` | Public HTTPS base URL encoded into QR pairing links |
| `VAPID_PUBLIC_KEY` + `VAPID_PRIVATE_KEY` | NIST P-256 VAPID keypair (base64url) for direct Web Push (`ES256`); auto-generated in `.watsafe-runtime/vapid_keys.json` during local runs when unset |
| `VAPID_SUBJECT` | Contact URI for VAPID JWT `sub` claim (default `mailto:alerts@watsafe.app`) |
| `AIVEN_DATABASE_URL` / `DATABASE_URL` | Optional PostgreSQL URI (`postgres://...`); falls back to in-memory store when unset |
| `AIVEN_CA_CERT_PATH` / `PGSSLROOTCERT` | Optional CA certificate path for `SslMode.verifyFull` |
| `FCM_PROJECT_ID` + `FCM_BEARER_TOKEN` / `FCM_SERVER_KEY` | Optional Firebase Cloud Messaging credentials for native Android/iOS push tokens |
| `APNS_BUNDLE_ID` + `APNS_AUTH_TOKEN` | Optional Apple Push Notification service HTTP/2 credentials for native iOS builds |
| `WATSAFE_PUSH_WEBHOOK_URL` | Optional external push gateway URL (verified on startup) |

---

## 5. Key Endpoints

| Endpoint | Auth | Description |
| :--- | :--- | :--- |
| `GET /`, `GET /pair`, `GET /companion` | Public HTML | Guided 5-state iPhone & Android Web Companion PWA |
| `GET /manifest.webmanifest`, `GET /sw.js`, `GET /icons/*` | Public PWA | Web App Manifest (`standalone`), icons (`192`, `512`, `180` Apple touch), and Service Worker |
| `GET /v1/health` | Public JSON | Readiness check, VAPID public key, and active `publicHttpsOrigin` |
| `POST /v1/pairing/initiate` | Optional `Bearer <hostToken>` | Generates a 5-minute single-use code and HTTPS `/pair?code=...` QR URL |
| `GET /v1/pairing/lookup?code=...` | Rate-limited | Non-consuming code preview returning `hostDisplayName` and `vapidPublicKey` |
| `POST /v1/pairing/complete` | Rate-limited `pairingCode` | Consumes single-use code, binds phone, and returns `companionToken` |
| `POST /v1/companion/handoff-code` | `Bearer <companionToken>` | Mints 10-minute single-use 6-char code to move pairing from iOS Safari into Home Screen web app |
| `POST /v1/companion/claim-handoff` | Rate-limited `handoffCode` | Transfers existing paired bond into Home Screen app and rotates `companionToken` |
| `POST /v1/companion/push-subscription` | `Bearer <companionToken>` | Validates & stores RFC 8291 Web Push subscription (`endpoint`, `p256dh`, `auth`) |
| `DELETE /v1/companion/push-subscription` | `Bearer <companionToken>` | Removes Web Push subscription and marks notifications disabled |
| `POST /v1/companion/status` | `Bearer <companionToken>` | Updates 5-state readiness and enforces honest `notificationsEnabled` status |
| `POST /v1/companion/test-alert` | `Bearer <companionToken>` | Dispatches immediate or delayed (`delaySeconds` `0..10`) real Web Push test alert |
| `POST /v1/companion/disconnect` | `Bearer <companionToken>` | Revokes companion bond from the phone |
| `POST /v1/pairing/session/revoke` | `Bearer <hostToken>` | Revokes only this host installation's session, bonds, push registrations, and alerts |
| `GET /v1/pairing/devices` | `Bearer <hostToken>` | Lists paired phones and accurate notification readiness for the host |
| `DELETE /v1/pairing/devices/<id>` | `Bearer <hostToken>` | Disconnects a phone and revokes its `companionToken` |
| `POST /v1/incidents:report` | `Bearer <hostToken>` | Records real or test alarm (`incidentId` deduplicated) and dispatches real Web Push |
| `POST /v1/incidents/location` | `Bearer <hostToken>` | Attaches asynchronous device location to an existing `incidentId` |
| `GET /v1/companion/alerts?afterSeq=<n>` | `Bearer <companionToken>` | Streams new and location-updated session alerts |
| `GET /v1/companion/events/<incidentId>` | `Bearer <companionToken \| hostToken>` | Authenticated single-event + location lookup |
