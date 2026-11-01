# WATSafe Backend & Remote Notification Boundary (`backend/`)

> **Milestone Status:** **Not Configured (Deferred to Team Area 4)**  
> The first WATSafe milestone runs 100% locally without a cloud account, API key, phone pairing, or paid service. The Flutter client uses `RemoteNotificationAdapter` (`lib/core/contracts/platform_contracts.dart`) and defaults to `UnconfiguredRemoteNotificationService` (`CapabilityStatus.notConfigured`).

---

## 1. Purpose & Security Boundary

The backend service is responsible for:

1. **Authenticated Device Registration & Pairing:** Linking a user's desktop laptop (`macOS` / `Windows`) with one or more mobile companion devices (`iOS` / `Android`) after verifying mutual ownership.
2. **Authenticated Incident Submission:** Receiving metadata-only incident payloads when an armed device enters `ProtectionState.alarming` or experiences a mid-session detector failure.
3. **Push Notification Relay (APNs & FCM):** Dispatching high-priority push notifications to paired mobile devices.

### Strict Security & Privacy Invariants

- **Server-Only Credentials:** Apple Push Notification service (`.p8` APNs auth keys) and Firebase Cloud Messaging (`service-account.json`) credentials **must reside exclusively on the backend server**. They must never be bundled in the Flutter app or committed to this repository.
- **No Camera Images or Video:** Incident payloads sent to the backend contain timestamps, detector modality, and normalized motion scores only. Camera frames never leave the local device memory.
- **No PIN Material:** The user's disarm PIN and its PBKDF2-HMAC-SHA256 salt/hash remain strictly local to each device's secure storage and are never transmitted to the backend.
- **Local Siren Independence:** The Flutter `AlarmController` triggers the local siren immediately before attempting any network call. A backend timeout, HTTP error, or unconfigured state never stops or delays a local alarm.

---

## 2. Planned Backend Data Models

### `DeviceRegistration`
| Field | Type | Description |
| :--- | :--- | :--- |
| `deviceId` | `UUID` | Unique server-assigned identifier for the installation |
| `ownerUserId` | `UUID` | Authenticated owner account ID |
| `displayName` | `String` | User-assigned label (e.g., `"MacBook Pro 14"` or `"iPhone 16"`) |
| `platform` | `Enum` | `macos` \| `windows` \| `ios` \| `android` |
| `role` | `Enum` | `protected_host` \| `alert_receiver` \| `both` |
| `pushProvider` | `Enum?` | `apns` \| `fcm` \| `null` |
| `pushToken` | `String?` | Encrypted device push token for mobile receivers |
| `lastSeenAtUtc` | `ISO-8601` | Last authenticated heartbeat or token refresh |

### `DevicePairingBond`
| Field | Type | Description |
| :--- | :--- | :--- |
| `bondId` | `UUID` | Unique pairing relationship ID |
| `ownerUserId` | `UUID` | Must match `ownerUserId` on both devices |
| `sourceDeviceId` | `UUID` | Protected device that emits incidents |
| `targetDeviceId` | `UUID` | Companion device that receives alerts |
| `createdAtUtc` | `ISO-8601` | Timestamp when the short-lived pairing code was verified |
| `revokedAtUtc` | `ISO-8601?` | Non-null if unpaired by the user |

### `RemoteIncidentReport`
| Field | Type | Description |
| :--- | :--- | :--- |
| `incidentId` | `String` | Client-generated incident ID (idempotency key) |
| `sourceDeviceId` | `UUID` | Authenticated device submitting the alert |
| `sessionId` | `String` | Protection session identifier |
| `kind` | `String` | `realDetectorTrigger` \| `detectorFailureDuringMonitoring` |
| `detectorType` | `String` | e.g., `macos_camera_scene_motion`, `windows_accelerometer` |
| `triggeredAtUtc` | `ISO-8601` | Timestamp of the trigger |
| `peakMotionScore` | `Double?` | Normalized motion score (`0.0`..`1.0`) |
| `triggerSummary` | `String` | Human-readable trigger summary |

---

## 3. Planned REST / HTTPS API Endpoints

1. `POST /v1/devices/register` — Registers a device and returns a signed device bearer token.
2. `POST /v1/pairing/initiate` — Generates a 6-character, single-use, 5-minute pairing code bound to `ownerUserId`.
3. `POST /v1/pairing/complete` — Verifies ownership and creates a `DevicePairingBond` between desktop and mobile devices.
4. `GET /v1/pairing/devices` — Lists active paired devices for the authenticated owner (maps to `RemoteNotificationAdapter.listPairedDevices()`).
5. `POST /v1/incidents:report` — Validates device ownership, stores the incident metadata idempotently, and dispatches APNs/FCM push notifications to all active `targetDeviceId`s paired with `sourceDeviceId` (maps to `RemoteNotificationAdapter.sendIncidentAlert()`).

---

## 4. Connecting the Flutter Client (Team Area 4 Handoff)

To connect a real backend in a feature branch without breaking local-only execution:

1. Implement `HttpRemoteNotificationService implements RemoteNotificationAdapter` in `lib/services/remote_notification_service.dart`.
2. Read the backend base URL via `--dart-define=WATSAFE_API_URL=...`.
3. When `WATSAFE_API_URL` is empty or omitted, keep returning `UnconfiguredRemoteNotificationService` so local development, CI, and offline usage continue working out of the box.
