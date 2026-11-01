# WATSafe Platform Capabilities & Limitations

This document records what is **Implemented**, **Tested**, and **Planned** across each target platform in the initial milestone, along with hardware and operating system constraints that affect user decisions.

---

## 1. Capability Matrix (Milestone 1)

| Subsystem / Feature | macOS | Windows | Android | iOS | Status in Code |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Shared Material 3 UI & Adaptive Shell** | Implemented | Implemented | Implemented | Implemented | Automated widget tests + macOS build |
| **Central Alarm State Machine (`AlarmController`)** | Implemented | Implemented | Implemented | Implemented | 7 focused unit test suites passing |
| **Salted PBKDF2-HMAC-SHA256 PIN & Lockout** | Implemented | Implemented | Implemented | Implemented | Tested (Keychain on macOS + 0600 file fallback) |
| **Local Looping Siren & 5s Test Alarm** | Implemented (`AVAudioPlayer`) | Fallback (`SystemSound`) | Fallback (`SystemSound`) | Fallback (`SystemSound`) | Tested on macOS (`assets/audio/alarm_siren.wav`) |
| **Local Incident & Settings Storage** | Implemented | Implemented | Implemented | Implemented | Tested (JSON persistence, zero images/PINs) |
| **Webcam Scene-Motion Detection** | **Implemented** (`AVFoundation`) | Planned (`MediaFoundation`) | N/A | N/A | Implemented & compiled on macOS; returns `notImplemented` on Windows |
| **Hardware Accelerometer Detection** | Unsupported (No public macOS API) | Planned (`WinRT Sensors`) | Planned (`SensorManager`) | Planned (`CMMotionManager`) | Returns `notImplemented` on Windows/Android/iOS |
| **Background / Foreground Service Lifecycle** | Implemented (`NSWorkspace` sleep/wake) | Planned | Planned (Android 14+ FGS) | Foreground-only (iOS limit) | macOS sleep/wake wired; mobile planned |
| **Device Pairing & Remote Push Alerts** | Interface ready | Interface ready | Interface ready | Interface ready | Explicitly shows `Not configured` |

---

## 2. Explicit Capability Status Values

Every `MotionDetectorAdapter` and `RemoteNotificationAdapter` reports one of the following distinct states (`CapabilityStatus` in `lib/core/models/detector_models.dart`):

- `ready` — Hardware is present, OS permission is granted, and the detector can arm immediately.
- `supported` — Hardware is present, awaiting configuration.
- `permissionRequired` — Hardware is present, but OS permission is `notDetermined`, `denied`, or `restricted`.
- `degraded` — Detector is running or available, but input quality is poor (e.g., covered camera lens or extreme low light).
- `unsupported` — Required hardware is absent or the detector belongs to a different operating system.
- `notImplemented` — Shared contract is wired into the UI and controller, but native platform implementation is scheduled for a teammate task. Never pretends to monitor.
- `notConfigured` — Requires external backend/pairing configuration not set up in this local milestone.

---

## 3. Platform-Specific Hardware & OS Notes

### macOS (`macos_camera_scene_motion`)
- **Why Camera Scene-Motion:** Apple does not expose an internal MacBook motion sensor via `CMMotionManager` on macOS.
- **How It Works:** Captures low-resolution frames via `AVFoundation` on a background queue, downsamples to `64x48` grayscale, calibrates a reference frame, and computes normalized pixel delta scores.
- **Honest Limitation:** Because this algorithm measures *scene motion*, it reacts to people moving in front of the laptop or abrupt lighting changes as well as physical laptop movement. Optical-flow camera ego-motion estimation is documented in `docs/roadmap.md` as a future improvement.
- **System Sleep / Lid Closure:** When macOS enters sleep (`NSWorkspace.willSleepNotification`), camera capture pauses and `AlarmController` transitions from `armed` (`PROTECTED`) to `paused` (`PAUSED`).

### Windows (`windows_accelerometer` & `windows_camera_scene_motion`)
- **Hardware Availability Check Required:** Only 2-in-1 convertibles and select Windows laptops include a sensor accessible via `Windows.Devices.Sensors.Accelerometer.GetDefault()`. When `GetDefault()` returns `nullptr`, the Windows adapter must report `CapabilityStatus.unsupported` and guide the user to the Windows webcam scene-motion detector.

### Android (`android_motion_sensors`)
- **Sensors:** Uses `SensorManager` (`Sensor.TYPE_LINEAR_ACCELERATION` with `Sensor.TYPE_ACCELEROMETER` fallback).
- **Foreground Service Requirement:** Android 14+ (API 34+) requires declaring a user-initiated foreground service with a persistent notification so sensor monitoring continues when the screen turns off.

### iOS (`ios_core_motion_foreground`)
- **Foreground-Only Live Monitoring:** iOS suspends standard applications shortly after screen locking or switching apps and does not permit indefinite background accelerometer capture.
- **Honest UX Rule:** On iOS, live `CMMotionManager` monitoring operates only while WATSafe remains in the foreground. If the app is backgrounded or the screen locks, the iOS adapter must emit `DetectorEventType.lifecyclePaused` so the app transitions to `paused` rather than falsely claiming `Protected`. Backgrounded iOS devices receive remote APNs push alerts from paired desktop laptops.

### Audio & OS Lock Limitations (All Platforms)
- WATSafe plays its siren through the active OS audio output device at the user-configured volume.
- WATSafe does **not** claim to prevent hardware power-off, OS force-quitting, headphone unplugging/rerouting, or physical hardware mute buttons. Its PIN screen disarms the WATSafe alarm and is separate from the operating system login/lock screen.
