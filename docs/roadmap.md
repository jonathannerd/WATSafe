# WATSafe Roadmap & Remaining Work

This roadmap reflects the current codebase. Older milestone documents listed several native integrations as planned before they were implemented; check current source and tests before reopening those tasks.

## 1. Implemented foundation

The repository now contains the following implementation areas:

- Shared Flutter UI and AlarmController state machine with generation guards, PIN disarm, incident history, lifecycle pause/resume, and local alarm handling.
- Salted PBKDF2-HMAC-SHA256 PIN verification with native storage bridges for macOS Keychain, Windows DPAPI, Android Keystore, and iOS Keychain. macOS also has a protected Application Support fallback.
- macOS AVFoundation camera monitoring and a shared Dart camera motion analyzer with optical-flow / camera ego-motion estimation, temporal filtering, lighting normalization, and obstruction warnings.
- Windows Media Foundation webcam capture, native camera motion processing, and optional WinRT / Sensor API accelerometer support.
- Android SensorManager motion detection and a user-visible foreground monitoring service.
- iOS Core Motion foreground detection with explicit pause on background/screen lock and guarded resume on foreground.
- Relay pairing, authenticated companion requests, location-sharing controls, Web Push and provider adapters, local file persistence, and PostgreSQL-backed relay persistence.
- Relay request hardening: bounded JSON bodies, failed handoff-code rate limiting, and removal of obsolete unauthenticated registration/watchdog routes (PR #22).

These are code-level implementation statements, not a claim that every path has been tested on every physical device.

## 2. Highest-priority remaining work

### 2.1 Benchmark production PIN KDF on supported devices
[Issue #23](https://github.com/jonathannerd/WATSafe/issues/23)

- Persistent failed-attempt count and UTC lockout deadlines are now included in secure PIN records and restored after service recreation.
- Older PIN records remain readable and are upgraded to the configured work factor after successful authentication.
- Storage-write failures preserve in-memory backoff and are surfaced; a valid PIN can still disarm after lockout expiry, but persistence status is explicit.
- Run `flutter test integration_test/pin_kdf_benchmark_test.dart -d <device-id>` on real macOS, Windows, Android, and iOS devices.
- Record benchmark results and tune the 600,000-iteration production target to keep verification responsive (general target: under one second).

### 2.2 Review macOS Keychain / Application Support duplication
[Issue #26](https://github.com/jonathannerd/WATSafe/issues/26)

- The native macOS bridge currently writes a protected Application Support copy even when the Keychain write succeeds.
- Decide whether the copy should be fallback-only or remain as a documented recovery mirror; retain safe migration behavior either way.

### 2.3 Native builds are now part of CI
[PR #24 — Add native platform build validation](https://github.com/jonathannerd/WATSafe/pull/24)

- GitHub Actions now compiles Web and Android on Linux, macOS and unsigned iOS on macOS, and Windows on a Windows runner.
- The initial full native validation run passed all five targets. Android CI pins JDK 17 to match the repository's Gradle 8.14 wrapper.
- Keep native build validation separate from the existing formatting / analysis / unit-test workflow.

### 2.4 Complete physical-device verification

Automated tests use fake sensors and mocked platform channels for many scenarios. Run and record the hardware checklist in docs/testing.md on actual Macs, Windows laptops, Android phones, and iPhones. Do not close native platform tasks solely because mocked tests pass.

### 2.5 Revisit detection thresholds only with measured evidence

The camera analyzer already includes ego-motion, landmark anchoring, optical flow, illumination normalization, obstruction detection, and synthetic false-alarm / pickup tests. Any further tuning should be driven by recorded false-positive and true-positive results from physical use, not speculative threshold changes.

### 2.6 Refresh older issue backlog

Issues #2–#9 predate substantial implementation work. In particular, Windows webcam detection, Windows accelerometer support, Android foreground motion monitoring, alarm state/lifecycle handling, and PIN/alarm integration tests now have corresponding code and automated tests. Review each issue against current implementation and remaining physical-device acceptance checks before assigning duplicate implementation work.

## 3. Development rule

Keep security changes, native platform changes, and documentation/cleanup in separate pull requests. For any change touching shared contracts, native channels, storage formats, or platform lifecycle behavior, add regression tests and preserve existing behavior on platforms not involved in the change.
