## Summary

<!-- Briefly describe what this PR implements or fixes and which ownership area (Area 1–4) it belongs to. -->

## Ownership Area

- [ ] Area 1 — Shared Flutter UI, State Logic, and Common Contracts
- [ ] Area 2 — macOS / Windows Native Monitoring and Desktop Integration
- [ ] Area 3 — Android / iOS Native Monitoring and Mobile Integration
- [ ] Area 4 — Backend, Device Pairing, Remote Notifications, and Incident Sync

## Shared File Coordination

- [ ] No shared coordination files (`pubspec.yaml`, `lib/core/contracts/platform_contracts.dart`, `lib/main.dart`) were modified, **OR** changes were coordinated with the team first.

## Verification & Honesty Checklist

- [ ] `dart format --output=none --set-exit-if-changed .` passes with zero changes.
- [ ] `flutter analyze` passes with zero issues.
- [ ] `flutter test` passes and new unit/widget tests cover the added behavior.
- [ ] Unimplemented or unavailable hardware states return explicit status (`unsupported`, `permissionRequired`, `notImplemented`, `notConfigured`) rather than pretending to monitor.
- [ ] No plaintext PINs, credentials, or camera frames are logged, persisted, or transmitted.

## Manual / Hardware Testing Notes

<!-- Describe what was tested on physical hardware or simulators, and note any hardware blockers. -->
