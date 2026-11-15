# WATSafe

**WATSafe** is a cross-platform device protection application built with Flutter and native platform adapters for **macOS**, **Windows**, **iOS**, **Android**, and the **Web / GitHub Codespaces** browser prototype.

Desktop builds protect laptops against unauthorized physical movement or tampering while armed. Mobile builds provide local motion monitoring (including Android 14+ Foreground Service background monitoring and foreground-scoped iOS Core Motion monitoring) and receive live session-scoped alerts from paired laptops.

---

## Current Capabilities Summary

| Capability | Status | Details |
|---|---|---|
| **Shared Adaptive UI (Material 3)** | **Implemented & Tested** | Charcoal / warm off-white / amber theme, onboarding PIN setup, protection dashboard, countdown, active alarm screen, incident history, settings, paired-devices QR/code UI, and remote laptop alarm banner. |
| **Central Alarm, Lifecycle & PIN Controller** | **Implemented & Tested** | Generation-guarded state machine (`disarmed`, `arming`, `armed`, `alarming`, `paused`, `unavailable`), single-flight PIN verification & siren cancellation (including pending siren startup), preserve-on-minimize active alarm behavior, and PBKDF2-HMAC-SHA256 salted PIN hashing. |
| **Camera Ego-Motion & Tamper Analysis** | **Implemented & Tested** | Shared & native (`Dart`, `Swift`, `C++`) `64x48` 4x4-quadrant Lucas-Kanade optical flow + per-block contrast-invariant stationary landmark anchoring that rejects people walking in front of a stationary laptop and sudden lighting shifts while triggering on laptop pickup, pan, or rotation. |
| **macOS & Windows Native Detectors** | **Implemented** | macOS `AVFoundation` (`NV12`/`BGRA`) and Windows Media Foundation MTA worker (`NV12`/`I420`/`YUY2`/`UYVY`/`RGB32`/`RGB24` with `IMF2DBuffer::Lock2D` row-stride handling + WinRT `Accelerometer`), first-frame verification timeout, and actionable permission/busy/missing-camera recovery. |
| **Android Background Motion Monitoring** | **Implemented** | `WatSafeMonitoringService` (`specialUse` Foreground Service on Android 14+ with persistent `"Stop Monitoring"` notification) + `Sensor.TYPE_LINEAR_ACCELERATION` / gravity-filtered `TYPE_ACCELEROMETER`. |
| **Laptop-to-Phone Pairing & Live Alerts** | **Implemented & Tested** | Short-lived (5-min) single-use pairing code & QR link, session-isolated bearer tokens, foreground phone alert polling with reconnect deduplication, strict frame/PIN/credential blocking, and optional Aiven PostgreSQL persistence via backend env vars. |

### Temporary Development Application Identifier
All native runners use **`dev.watsafe.temp.watsafe`** so local development works without paid developer accounts. Replace before signed store distribution.

---

## Quick Start & Verification Commands

### 1. Install Dependencies & Run Automated Checks
```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

### 2. Run on macOS Desktop
```bash
flutter run -d macos
```

### 3. Run the Browser Prototype (Local or GitHub Codespaces)
```bash
flutter build web --no-web-resources-cdn
flutter run -d web-server --web-hostname=0.0.0.0 --web-port=8080 --no-web-resources-cdn
```
*(In GitHub Codespaces, open the forwarded HTTPS port `8080` so `navigator.mediaDevices.getUserMedia` has a secure context.)*

### 4. Run Laptop-to-Phone Pairing & Optional Aiven PostgreSQL Relay
Start the standalone relay server (uses in-memory storage by default, or Aiven PostgreSQL when `AIVEN_DATABASE_URL` is exported):
```bash
# Optional — Chuan's Aiven PostgreSQL test database (keep credentials in env vars only):
# export AIVEN_DATABASE_URL="postgres://avnadmin:<password>@<host>.aivencloud.com:<port>/defaultdb?sslmode=require"

dart run backend/server.dart 8787
```
See [`backend/README.md`](backend/README.md) for full LAN/phone pairing steps, Aiven PostgreSQL integration test instructions, and APNs/FCM background push deployment requirements.

### 5. Run UI Integration Tests on a Supported Host
```bash
# Headless widget/integration suite (runs anywhere, including CI):
flutter test test/pin_alarm_integration_test.dart

# Full native runner integration test (on a desktop with GUI session):
flutter test integration_test/pin_disarm_integration_test.dart -d macos
```

---

## Platform Lifecycle & Security Notes

- **Active Alarm Across Minimize/Suspend:** Once `ProtectionState.alarming` triggers, minimizing or backgrounding the app preserves the active alarm and incident; only entering the valid 6+ digit PIN disarms it. If the OS or browser suspends audio while hidden, WATSafe displays an explicit interruption notice and a one-tap **Resume Siren Audio** control alongside PIN entry.
- **Pre-Trigger Monitoring Across Minimize/Suspend:** Webcam and iOS foreground monitoring pause honestly when minimized/backgrounded (`PAUSED`, never `Protected`) and automatically restore without duplicate streams on resume. Android continues monitoring in the background while `WatSafeMonitoringService` is active.
- **Foreground Companion Phone Alerts:** Without external APNs/FCM server credentials, paired phones receive live alerts while WATSafe is open in the foreground.
- **Privacy & Credential Invariant:** Camera frames are processed strictly in volatile memory and never saved or transmitted. PINs, PBKDF2 hashes, and database credentials never cross the network connection.
