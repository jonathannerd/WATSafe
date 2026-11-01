# Contributing to WATSafe

Welcome to the WATSafe team repository! Four students share this codebase across four ownership areas. Follow these rules to keep `main` stable and reviews fast.

---

## 1. Branch & Pull Request Workflow

1. **Sync with `main` before starting a task:**
   ```bash
   git checkout main
   git pull origin main
   ```
2. **Create one feature branch per task:**
   ```bash
   git checkout -b feat/<area>-<task-slug>
   ```
   Examples:
   - `feat/windows-accelerometer-winrt`
   - `feat/android-foreground-service`
   - `feat/ios-coremotion-foreground`
   - `feat/backend-pairing-endpoints`
3. **Keep pull requests focused:**
   - Do not bundle unrelated UI refactors with native platform channel changes.
   - Coordinate in advance before modifying shared files (`pubspec.yaml`, `lib/core/contracts/platform_contracts.dart`, `lib/main.dart`). See [docs/team-workflow.md](docs/team-workflow.md) for details.

---

## 2. Required Local Checks Before Opening a PR

Run all three commands from the repository root and ensure they pass with zero warnings or errors:

```bash
# Format code (or verify formatting matches CI)
dart format .
dart format --output=none --set-exit-if-changed .

# Static analysis
flutter analyze

# Automated tests
flutter test
```

If you changed native code (`macos/`, `windows/`, `ios/`, `android/`), also build and test the native target on your machine and document your test results in the Pull Request description.

---

## 3. Architectural & Honesty Rules

1. **Never fake hardware monitoring:**
   - If a platform sensor or permission is missing, return `DetectorAvailabilityState.unsupported`, `permissionRequired`, or `notImplemented`.
   - Never display a green "Protected" state unless a real detector is actively streaming or calibrated.
2. **Never log or transmit sensitive data:**
   - Never log plaintext PINs, PBKDF2 hashes, or pairing tokens.
   - Never save, cache, or upload camera frames. All webcam motion detection must remain strictly in local volatile memory.
3. **Isolate alarm playback from storage/network failures:**
   - Local siren playback must start immediately when an armed detector triggers, without awaiting disk writes or remote notification HTTP calls.
4. **Distinguish test incidents from real triggers:**
   - Any simulated or test trigger must set `isTest: true` so it is clearly labeled `[TEST]` in the UI and incident logs.
