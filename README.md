#Test

# WATSafe

**WATSafe** is a cross-platform device protection application built with Flutter and native platform adapters for **macOS**, **Windows**, **iOS**, and **Android**.

Desktop builds protect laptops against unauthorized tampering or movement while armed. Mobile builds are architected to provide local device motion protection where permitted by the OS and to receive remote alerts from paired devices once the backend service is connected.

---

## Milestone 1 Status Summary

| Capability | Status in Milestone 1 | Notes |
|---|---|---|
| **Shared Adaptive UI (Material 3)** | **Implemented & Tested** | Charcoal / warm off-white / amber theme, onboarding PIN setup, dashboard, arming countdown, alarm overlay, incident history, settings, and paired devices screen. |
| **Central Alarm & PIN Controller** | **Implemented & Tested** | Explicit state machine (`disarmed`, `arming`, `armed`, `alarming`, `paused`, `unavailable`), single-incident deduplication, PBKDF2-HMAC-SHA256 salted PIN hashing (6–12 digits), stepped lockout delays, and 5-second max Test Alarm. |
| **macOS Webcam Scene-Motion Detector** | **Implemented (Native `AVFoundation`)** | Downsampled `64x48` grayscale frame differencing off the UI thread (`dev.watsafe/macos_camera`), calibration window, persistence filtering, and low-light/covered-lens degradation warnings. |
| **macOS Local Siren & Secure PIN Storage** | **Implemented (Native `AVAudioPlayer` & Keychain/Sandbox)** | Loops `assets/audio/alarm_siren.wav` locally without awaiting disk/network I/O. Stores PIN hash in macOS Keychain with `0600` sandboxed Application Support fallback for ad-hoc local builds. |
| **Windows / Android / iOS Native Detectors** | **Contracts Ready (`Not implemented`)** | Typed Dart adapters and platform channel contracts in place; explicitly report `Not implemented` until native runners are wired in Milestone 2. |
| **Device Pairing & Remote Notifications** | **Contracts Ready (`Not configured`)** | Runs 100% locally without cloud accounts or API keys. Shows an honest `Not configured` state until the backend is connected. |

### Temporary Development Application Identifier
All four platform runners use the temporary development identifier **`dev.watsafe.temp.watsafe`** (`PRODUCT_BUNDLE_IDENTIFIER` on macOS/iOS, `applicationId` on Android) so local development and testing work out of the box without paid developer accounts. Replace this identifier before distributing signed release builds.

---

## Development Environment & Verified Versions

- **Flutter:** `3.41.6` (channel `stable`)
- **Dart:** `3.11.4`
- **macOS Host Tested:** macOS `27.0.1` (`arm64`), Xcode `27.1`, CocoaPods `1.16.2`, macOS deployment target `13.0`
- **Dependencies:** Pure-Dart, cross-platform verified packages (`cryptography: ^2.9.0`, `crypto: ^3.0.8`), committed with `pubspec.lock`.

---

## Quick Start Commands

### 1. Clone and Install Dependencies
```bash
git clone https://github.com/jonathannerd/WATSafe.git
cd WATSafe
flutter pub get
```

### 2. Run Automated Checks (Formatting, Analyzer, Tests)
```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

### 3. Run the Application Locally (macOS Desktop)
```bash
flutter run -d macos
```

Or build and launch the macOS `.app` bundle directly:
```bash
flutter build macos --debug
open build/macos/Build/Products/Debug/WATSafe.app
```

---

## Repository Structure

```text
WATSafe/
├── lib/
│   ├── main.dart                          # App entrypoint & service wiring
│   ├── core/
│   │   ├── alarm/                         # AlarmController state machine & AlarmState
│   │   ├── contracts/                     # Typed platform, audio, storage, and notification contracts
│   │   └── models/                        # Detector, incident, and settings models
│   ├── features/                          # Adaptive Material 3 screens & theme
│   ├── platform/
│   │   ├── desktop/                       # macOS webcam adapter & Windows sensor/camera stubs
│   │   ├── mobile/                        # Android & iOS motion detector stubs
│   │   └── platform_detector_registry.dart
│   └── services/                          # PBKDF2 PIN security, storage, audio, & remote alert services
├── macos/                                 # Native macOS runner + AVFoundation/AVAudioPlayer/Keychain bridges
├── windows/                               # Native Windows runner (C++/WinRT integration target)
├── ios/                                   # Native iOS runner (Core Motion integration target)
├── android/                               # Native Android runner (SensorManager/ForegroundService target)
├── assets/audio/alarm_siren.wav           # Local looping alarm siren asset
├── backend/README.md                      # Future backend API & security specification
├── docs/                                  # Architecture, capabilities, workflow, roadmap, & testing docs
└── test/                                  # Automated controller unit tests & widget tests
```

---

## Documentation Index

- [Architecture & Platform Contracts](docs/architecture.md)
- [Platform Capabilities Matrix (Implemented / Tested / Planned)](docs/platform-capabilities.md)
- [Team Workflow & 4-Person Ownership Plan](docs/team-workflow.md)
- [Roadmap & Next Assignable Team Tasks](docs/roadmap.md)
- [Testing Guide & Hardware Verification Checklist](docs/testing.md)
- [Future Backend Boundary & API Contract](backend/README.md)
- [Contributing Guidelines](CONTRIBUTING.md)

---

## Honest Security & Operating System Limitations

- **Scene-Motion vs. Theft Verification:** The Milestone 1 macOS webcam detector performs local `64x48` grayscale frame-difference scene-motion detection. It reacts to physical movement of the laptop as well as people or strong lighting changes in front of the camera. Optical-flow camera ego-motion estimation is planned as a future enhancement.
- **No Camera Retention:** Camera frames are processed strictly in volatile memory off the UI thread and are never saved to disk or transmitted over the network.
- **OS Lock & Hardware Controls:** WATSafe's in-app PIN screen controls the application alarm state. It does **not** replace macOS FileVault/login lock screens, and it cannot prevent physical hardware power-off, closing the laptop lid to force hardware sleep, or muting system audio at the OS level. Lock your operating system screen (`Ctrl+Cmd+Q` on macOS, `Win+L` on Windows) alongside arming WATSafe.
