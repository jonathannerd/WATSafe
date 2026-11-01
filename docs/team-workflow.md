# Team Workflow & Ownership Plan

WATSafe is designed for parallel development by **four teammates** without stepping on each other's files or breaking the main branch.

> **Important:** Do not assign real teammate names or GitHub usernames in repository configuration files. Coordinate ownership in your team channel and claim tasks from [docs/roadmap.md](roadmap.md).

---

## 1. Four-Person Task Ownership Plan

### Area 1 — Shared Flutter UI, State Logic, and Common Contracts
- **Primary Directories:**
  - `lib/core/` (`alarm/`, `contracts/`, `models/`)
  - `lib/features/` (`alarm/`, `dashboard/`, `incidents/`, `onboarding/`, `paired_devices/`, `settings/`, `shell/`, `theme/`)
  - `test/` (unit and widget tests)
- **Responsibilities:**
  - Maintain `AlarmController` state transitions (`disarmed`, `arming`, `armed`, `alarming`, `paused`, `unavailable`).
  - Maintain adaptive Material 3 desktop/mobile UI, accessibility, keyboard navigation, and status truthfulness.
  - Coordinate updates to shared contracts in `lib/core/contracts/platform_contracts.dart`.

### Area 2 — macOS & Windows Native Monitoring and Desktop Integration
- **Primary Directories:**
  - `lib/platform/desktop/` (`macos_camera_detector.dart`, `windows_detectors.dart`)
  - `macos/Runner/` (`MainFlutterWindow.swift`, entitlements, `Info.plist`)
  - `windows/runner/` (C++/WinRT sensor and audio plugins)
- **Responsibilities:**
  - Maintain macOS `AVFoundation` webcam scene-motion detection, native audio playback, and Keychain/sandboxed PIN storage.
  - Implement Windows `Windows.Devices.Sensors.Accelerometer` and optional Windows camera detection behind `dev.watsafe/windows_accelerometer` and `dev.watsafe/windows_camera`.
  - Implement native Windows siren playback and DPAPI/Credential Locker PIN storage.

### Area 3 — Android & iOS Native Monitoring and Mobile Integration
- **Primary Directories:**
  - `lib/platform/mobile/` (`android_motion_detector.dart`, `ios_motion_detector.dart`)
  - `android/app/src/main/` (`MainActivity.kt`, foreground service, `AndroidManifest.xml`)
  - `ios/Runner/` (`AppDelegate.swift`, `Info.plist`)
- **Responsibilities:**
  - Implement Android `SensorManager` accelerometer/gyroscope detector and user-initiated foreground service (`specialUse` / `connectedDevice` as appropriate for target SDK) with persistent notification and lifecycle handling.
  - Implement iOS `CMMotionManager` foreground motion detector and explicit pause/warning behavior when the app enters background or the screen locks.
  - Implement native mobile audio alarm bridges and Keychain / EncryptedSharedPreferences PIN storage bridges.

### Area 4 — Backend, Device Pairing, Remote Notifications, and Incident Sync
- **Primary Directories:**
  - `backend/` (service implementation, database migrations, OpenAPI spec)
  - `lib/services/remote_notification_service.dart`
  - `lib/features/paired_devices/` (pairing flow UI once backend is ready)
- **Responsibilities:**
  - Build the REST/WebSocket backend described in [backend/README.md](../backend/README.md).
  - Implement authenticated short-lived pairing codes, device ownership verification, incident submission (`POST /v1/incidents`), and server-side APNs/FCM push dispatch.
  - Replace `UnconfiguredRemoteNotificationService` with a configurable client adapter while keeping server credentials strictly on the server.

---

## 2. Shared Files Requiring Coordination

Most work stays isolated inside a single ownership directory. However, changes to the following files affect everyone and must be coordinated before merging:

| File | Why Coordination Is Needed | Protocol |
|---|---|---|
| `pubspec.yaml` & `pubspec.lock` | Adding/upgrading dependencies affects all 4 target platforms. | Verify target-platform support on pub.dev, run `flutter pub get`, commit updated `pubspec.lock`, and announce in team chat. |
| `lib/core/contracts/platform_contracts.dart` | Defines interfaces implemented by all desktop, mobile, storage, audio, and notification adapters. | Propose contract changes in a small standalone PR or review with Area 1 before modifying method signatures. |
| `lib/core/models/*.dart` | Shared domain models serialized to disk or passed across platform channels. | Maintain backward-compatible JSON serialization defaults. |
| `lib/platform/platform_detector_registry.dart` | Wires platform detectors into the app at startup. | Only edit the branch for your target OS (`TargetPlatform`). |
| `lib/main.dart` | Application entrypoint and dependency wiring. | Keep `main.dart` thin; encapsulate platform logic inside your adapter class. |

---

## 3. Git Workflow & Branching Strategy

### First Push & Teammate Onboarding
1. The initial bootstrapper commits the foundation to `main` and pushes to `origin`:
   ```bash
   git add -A
   git commit -m "Initialize WATSafe cross-platform foundation"
   git push -u origin main
   ```
2. The other three teammates clone the repository after the first push:
   ```bash
   git clone https://github.com/jonathannerd/WATSafe.git
   cd WATSafe
   flutter pub get
   flutter test
   ```

### One Feature Branch Per Task
Never commit directly to `main` after the initial foundation push. Create a descriptive branch for each task:

```bash
git checkout main
git pull origin main
git checkout -b feat/windows-accelerometer-bridge
```

Branch naming conventions:
- `feat/<area>-<short-description>` (new functionality)
- `fix/<area>-<short-description>` (bug fixes)
- `docs/<short-description>` (documentation updates)
- `test/<short-description>` (test coverage improvements)

### Optional: Using Git Worktrees for Parallel Local Work
After the first commit exists on `main`, you can use `git worktree` to inspect or test another branch without stashing your current work:

```bash
# Create an isolated worktree in a sibling folder
git worktree add ../WATSafe-review origin/main

# Remove the worktree when finished
git worktree remove ../WATSafe-review
```

### Pre-PR Verification Checklist
Every teammate is responsible for testing their own changes before opening a pull request:

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```
