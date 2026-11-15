# WATSafe Backend Relay & Companion Alert Service (`backend/`)

The standalone WATSafe Relay Server (`backend/server.dart`) connects a protected laptop (`macOS`, `Windows`, or Browser prototype) with a paired companion phone (`Android`, `iOS`, or Browser) using short-lived, single-use pairing codes and session-scoped bearer tokens.

By default, the relay runs 100% locally in memory with zero external accounts or API keys. When `AIVEN_DATABASE_URL` (or `DATABASE_URL`) is provided in the backend environment, it automatically persists pairing sessions, device bonds, and sanitized incident alerts to PostgreSQL (including Aiven Cloud PostgreSQL over TLS).

---

## 1. Security & Privacy Boundary

- **Strict Payload Sanitization:** `POST /v1/incidents:report` recursively inspects every incoming JSON key and string value and rejects (`400 PRIVACY_INVARIANT_VIOLATION`) any payload containing camera frames/images (`frame*`, `image*`, `rgba`, `nv12`, `data:image/*`, etc.), PIN material (`pin`, `pinHash`, `pbkdf2`, `salt*`), or database/cloud credentials (`databaseUrl`, `aiven*`, `postgres://`, `privateKey`, `serviceAccount`).
- **Session Isolation:**
  - `POST /v1/pairing/initiate` issues a 5-minute, single-use 6-character pairing code (`K7M-4P9`) and `watsafe://pair?...` QR payload alongside a cryptographic `hostToken` bound to `pairingSessionId`.
  - `POST /v1/pairing/complete` consumes the single-use pairing code and issues a `companionToken` bound strictly to that `pairingSessionId` (never exposing `hostToken` to the phone).
  - `GET /v1/companion/alerts` requires `Authorization: Bearer <companionToken>` and returns **only** alerts recorded for that companion's `pairingSessionId`. Unpaired or revoked sessions receive `401 Unauthorized`.
- **Reconnect & Retry Idempotency:** Incident reports are deduplicated on the server by `(pairingSessionId, incidentId)` and on the phone by `incidentId` + monotonic `alertSeq`, so network retries or phone reconnects never duplicate alerts.
- **Server-Only Credentials:** Database URLs (`AIVEN_DATABASE_URL` / `DATABASE_URL`) and future APNs (`.p8`) / FCM (`service-account.json`) credentials live strictly in backend environment variables—never in Flutter client code or HTTP responses.
- **Local Siren Independence:** `AlarmController` triggers the local siren first before dispatching any HTTP relay request.

---

## 2. Running the Relay Locally (In-Memory Default)

```bash
dart run backend/server.dart 8787
```

Health check:
```bash
curl http://127.0.0.1:8787/v1/health
```

### Pairing a Laptop and Phone on the Same Wi-Fi / LAN (or Codespaces Port)
1. Find your laptop's LAN IP (for example `192.168.1.42`) or forwarded HTTPS port URL.
2. Start `dart run backend/server.dart 8787` (binds `0.0.0.0:8787` by default; override with `WATSAFE_BIND_HOST`).
3. On the **Laptop** in WATSafe -> **Paired Devices**:
   - Enter `http://<laptop-lan-ip>:8787` in **Backend Relay URL** and click **Save Relay URL**.
   - Click **Generate Code & QR** to display the 5-minute single-use code and QR payload.
4. On the **Phone** in WATSafe -> **Paired Devices**:
   - Under **2. Companion Phone — Pair with Laptop & Receive Alerts**, paste the `watsafe://pair?...` link (or enter the Relay URL + 6-character code) and tap **Connect Phone to Laptop**.
5. The laptop automatically updates to **READY — Connected (1 paired device)**, and triggering an alarm on the laptop immediately delivers a **REMOTE LAPTOP ALARM** banner and alert entry on the paired phone while WATSafe is open in the foreground.

> **Foreground vs. Background Push Delivery:** Out of the box (without Apple/Google developer push keys), companion phones receive live alerts via authenticated foreground polling while WATSafe is open on screen. Delivering wake-up push notifications when the mobile OS terminates or backgrounds the app requires deploying this relay over HTTPS with server-side APNs (`.p8` key, Key ID, Team ID) and Firebase Cloud Messaging (`GOOGLE_APPLICATION_CREDENTIALS`) environment variables.

---

## 3. Running & Testing with Chuan's Aiven PostgreSQL Database

Keep all Aiven credentials in shell environment variables (never edit source files or commit `.env` files).

### Environment Variables
| Variable | Required | Description |
| :--- | :--- | :--- |
| `AIVEN_DATABASE_URL` | Yes (or `DATABASE_URL`) | Full Aiven PostgreSQL service URI, e.g. `postgres://avnadmin:<password>@<service>.aivencloud.com:<port>/defaultdb?sslmode=require` |
| `AIVEN_CA_CERT_PATH` | Optional | Path to Aiven `ca.pem` certificate file to enforce `SslMode.verifyFull` (`PGSSLROOTCERT` is also recognized) |
| `WATSAFE_DB_TABLE_PREFIX` | Optional | Table prefix (defaults to `watsafe_`; tests use `watsafe_it_`) |
| `PORT` | Optional | HTTP port for `backend/server.dart` (defaults to `8787`) |

### Start the Relay Backed by Aiven PostgreSQL
```bash
export AIVEN_DATABASE_URL="postgres://avnadmin:<password>@<host>.aivencloud.com:<port>/defaultdb?sslmode=require"
# Optional if verifying against Aiven's project CA certificate:
# export AIVEN_CA_CERT_PATH="$HOME/Downloads/ca.pem"

dart run backend/server.dart 8787
```
On startup, the relay prints `(storage: aiven_postgres — postgres://avnadmin@<host>:<port>/defaultdb)` (password redacted) and automatically creates:
- `watsafe_pairing_sessions`
- `watsafe_companion_bonds`
- `watsafe_session_alerts`

### Run the Automated Aiven Integration Test
When `AIVEN_DATABASE_URL` is exported, the live PostgreSQL integration test in `test/platform_and_pairing_test.dart` automatically unsuspends and verifies session creation, single-use code pairing, and alert persistence against Aiven:

```bash
AIVEN_DATABASE_URL="postgres://avnadmin:<password>@<host>.aivencloud.com:<port>/defaultdb?sslmode=require" \
  flutter test test/platform_and_pairing_test.dart
```

---

## 4. REST API Endpoints

| Method & Path | Auth | Purpose |
| :--- | :--- | :--- |
| `GET /v1/health` | Public | Returns `{status, storageBackend, deliveryMode}` (never credentials) |
| `POST /v1/pairing/initiate` | Optional `Bearer <hostToken>` | Creates or rotates a 5-minute single-use `pairingCode` + `qrPayload` for a laptop session |
| `POST /v1/pairing/complete` | Single-use `pairingCode` (or `Bearer <hostToken>`) | Consumes `pairingCode`, binds phone to `pairingSessionId`, and returns `companionToken` |
| `GET /v1/pairing/devices` | `Bearer <hostToken>` | Lists active paired phones for that laptop session only |
| `DELETE /v1/pairing/devices/<deviceId>` | `Bearer <hostToken>` | Unpairs `<deviceId>` and immediately revokes its `companionToken` |
| `POST /v1/incidents:report` | `Bearer <hostToken>` | Rejects frame/PIN/credential fields (`400`), deduplicates by `incidentId`, and records a session-scoped alert |
| `GET /v1/companion/alerts?afterSeq=<n>` | `Bearer <companionToken>` | Returns new alerts (`alertSeq > afterSeq`) strictly for that companion's `pairingSessionId` |
