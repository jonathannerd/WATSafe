# WATSafe Roadmap & Next Assignable Team Tasks

This document defines the immediate next tasks after the Milestone 1 foundation. Each task is scoped so that one teammate can complete, test, and open a pull request independently.

---

## Area 1 — Shared Flutter UI, Core Logic & Vision Refinement

### Task 1.1: Optical-Flow Ego-Motion Refinement (macOS / Desktop)
- **Goal:** Upgrade the scene-motion algorithm to distinguish ambient scene movement (a person walking past at a distance) from global camera translation/rotation (someone lifting or tilting the laptop).
- **Files:** `macos/Runner/MainFlutterWindow.swift`, `lib/core/models/detector_models.dart`, `docs/platform-capabilities.md`.
- **Acceptance Criteria:**
  - Estimate 4x4 grid block translation vectors or sparse Lucas-Kanade optical flow across downsampled `64x48` frames.
  - Trigger high-confidence movement events when coherent global motion vectors occur across the majority of blocks.
  - Preserve the existing scene-motion mode as a user-selectable sensitivity option.

### Task 1.2: Desktop Window Lifecycle & Fullscreen Alarm Focus
- **Goal:** Improve desktop alarm visibility and keyboard ergonomics during active alarms.
- **Files:** `lib/features/alarm/active_alarm_overlay.dart`, `lib/features/shell/watsafe_shell.dart`.
- **Acceptance Criteria:**
  - Support numeric keypad and hardware keyboard entry directly when the alarm overlay appears without requiring a mouse click into the text field.
  - Add unit and widget tests verifying focus and keyboard submission.

### Task 1.3: Incident Export & Filtering
- **Goal:** Allow users to filter local incident history (Real vs. Test, date range) and export a sanitized JSON/CSV diagnostic summary.
- **Files:** `lib/features/incidents/incidents_screen.dart`, `lib/services/local_storage_service.dart`.
- **Acceptance Criteria:**
  - Filter chips on the Incidents screen (`All`, `Real Triggers`, `Test Alarms`).
  - Export includes only sanitized incident metadata (no PINs, no raw images).

---

## Area 2 — Desktop Native Integrations (Windows & macOS)

### Task 2.1: Windows Hardware Accelerometer Adapter (C++/WinRT)
- **Goal:** Implement real hardware motion detection on Windows laptops/tablets equipped with an integrated accelerometer.
- **Files:** `windows/runner/flutter_window.cpp`, `lib/platform/desktop/windows_detectors.dart`.
- **Acceptance Criteria:**
  - Implement MethodChannel `dev.watsafe/windows_accelerometer` and EventChannel `dev.watsafe/windows_accelerometer_events` using `Windows.Devices.Sensors.Accelerometer::GetDefault()`.
  - Return `DetectorAvailabilityState.unsupported` when `GetDefault()` returns `nullptr` (standard non-convertible desktops/laptops without an HID sensor hub).
  - Compute magnitude delta from $1\,\text{g}$ resting baseline and emit `DetectorEvent` records when thresholds are exceeded.

### Task 2.2: Windows Webcam Scene-Motion & Native Audio/DPAPI Bridges
- **Goal:** Provide webcam motion detection, native looping siren playback, and DPAPI secure PIN storage on Windows.
- **Files:** `windows/runner/`, `lib/platform/desktop/windows_detectors.dart`, `lib/services/audio_alarm_service.dart`, `lib/services/secure_pin_storage_service.dart`.
- **Acceptance Criteria:**
  - Implement `dev.watsafe/windows_camera` using Windows Media Foundation (`IMFMediaSource`) with `64x48` grayscale frame differencing.
  - Implement `dev.watsafe/audio_alarm` on Windows so alarms play a continuous siren rather than fallback system alert sounds.
  - Implement `dev.watsafe/secure_storage` using Windows `CryptProtectData` (DPAPI) or `PasswordVault`.

---

## Area 3 — Mobile Native Integrations (Android & iOS)

### Task 3.1: Android Accelerometer & Linear Acceleration Detector
- **Goal:** Implement real hardware pickup/tilt detection on Android using `SensorManager`.
- **Files:** `android/app/src/main/kotlin/.../MainActivity.kt`, `lib/platform/mobile/android_motion_detector.dart`.
- **Acceptance Criteria:**
  - Register `Sensor.TYPE_LINEAR_ACCELERATION` (or `Sensor.TYPE_ACCELEROMETER` with gravity high-pass filter) behind `dev.watsafe/android_motion` and `dev.watsafe/android_motion_events`.
  - Include a 2-second settling window after arming before reporting triggers.
  - Implement `dev.watsafe/audio_alarm` (`MediaPlayer` / `AudioTrack` on `USAGE_ALARM`) and `dev.watsafe/secure_storage` (`AndroidKeyStore`).

### Task 3.2: Android User-Initiated Foreground Monitoring Service
- **Goal:** Keep Android motion monitoring alive when the screen turns off while armed.
- **Files:** `android/app/src/main/AndroidManifest.xml`, `android/app/src/main/kotlin/.../`.
- **Acceptance Criteria:**
  - Declare necessary foreground service permissions and service types in `AndroidManifest.xml` for Android 14+ (`API 34+`).
  - Show a persistent, user-visible notification (`WATSafe is armed and monitoring motion`) whenever armed.
  - Stop the foreground service immediately on PIN disarm.

### Task 3.3: iOS Core Motion Foreground Detector & Lifecycle Pause
- **Goal:** Implement foreground physical motion detection on iOS with honest background/lock suspension handling.
- **Files:** `ios/Runner/AppDelegate.swift`, `lib/platform/mobile/ios_motion_detector.dart`, `ios/Runner/Info.plist`.
- **Acceptance Criteria:**
  - Add `NSMotionUsageDescription` to `ios/Runner/Info.plist`.
  - Stream `CMMotionManager.startDeviceMotionUpdates` over `dev.watsafe/ios_motion_events` while the app is in the foreground.
  - Automatically enable `UIApplication.shared.isIdleTimerDisabled = true` while armed in the foreground, and transition `AlarmController` to `paused` with a clear banner if the user locks the phone or backgrounds the app.

---

## Area 4 — Backend, Pairing & Remote Notifications

### Task 4.1: Pairing & Incident Relay Backend Service
- **Goal:** Implement the minimal REST API specified in [backend/README.md](../backend/README.md).
- **Files:** `backend/` (server code, Dockerfile/compose for local dev, unit tests).
- **Acceptance Criteria:**
  - Implement `POST /v1/devices/register`, `POST /v1/pairings/request`, `POST /v1/pairings/confirm`, `GET /v1/pairings`, `DELETE /v1/pairings/:pairingId`, and `POST /v1/incidents`.
  - Enforce 6-digit pairing token expiration (10 minutes), rate limiting, and schema validation rejecting any payload containing raw images or PIN fields.
  - Provide a local development mode that logs push payloads to stdout without requiring paid APNs/FCM credentials.

### Task 4.2: Client Pairing UI & Remote Notification Service Integration
- **Goal:** Connect the Flutter app's Paired Devices screen and `RemoteNotificationService` to the backend API.
- **Files:** `lib/services/remote_notification_service.dart`, `lib/features/paired_devices/paired_devices_screen.dart`.
- **Acceptance Criteria:**
  - Allow optional backend URL configuration via `--dart-define=WATSAFE_API_URL=...` or Settings.
  - Keep `RemoteNotificationServiceState.notConfigured` as the default when no backend URL is configured.
  - Verify that `AlarmController` still sounds the local siren immediately even if `dispatchIncidentAlert` times out or returns HTTP 500.
