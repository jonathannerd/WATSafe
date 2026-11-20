# Testing Guide & Hardware Verification Checklist

WATSafe uses automated unit/widget tests, CI checks, and manual physical-device verification. A mocked platform-channel test proves Dart/native contract handling; it does not prove that the corresponding OS service or hardware behaves correctly on a real device.

## 1. Automated checks

Run these commands from the repository root:

    flutter pub get
    dart format --output=none --set-exit-if-changed .
    flutter analyze
    dart analyze tool/ backend/ lib/
    flutter test

The main CI workflow runs dependency installation, repository-wide Dart formatting, Flutter analysis, standalone backend/CLI analysis, and the automated test suite. A separate native-platform workflow compiles Web and Android on Linux, macOS and unsigned iOS on macOS, and Windows on Windows. The Android build job pins JDK 17 to match the repository Gradle wrapper.

### Automated coverage

- **Alarm and PIN state:** PIN creation / validation, correct and incorrect PIN handling, lockout backoff, PIN changes, arming, pause/resume, detector failure, duplicate alarms, and disarming during pending audio startup.
- **Secure storage:** native-channel success, stale fallback cleanup, file fallback on native write failure, and deletion.
- **Camera processing:** supported pixel formats and row strides, synthetic passersby / lighting / pickup / carry / slow-slide scenarios, and obstruction warnings.
- **Native adapter contracts:** mocked Windows camera, Android sensor/foreground service, iOS Core Motion lifecycle, audio, and location channels.
- **Relay and pairing:** authentication/session isolation, pairing handoff codes, rate limits, bounded request bodies, push handling, and storage behavior.

The live PostgreSQL integration test is skipped unless AIVEN_DATABASE_URL or DATABASE_URL is configured.

## 2. macOS physical-device checklist

- [ ] Run flutter run -d macos or open a debug build on a Mac.
- [ ] Complete first-run onboarding and create a 6–12 digit PIN.
- [ ] Grant camera permission and confirm the detector reports ready only after capture starts.
- [ ] Arm, allow calibration to finish, then test laptop lift / tilt / carry and a person walking through the background.
- [ ] Cover the camera and confirm the app reports degraded / obstructed input honestly.
- [ ] Trigger the siren, enter a wrong PIN, then the correct PIN; confirm wrong PIN leaves the alarm active and correct PIN stops it.
- [ ] Restart the app and confirm the PIN remains available through Keychain.
- [ ] Verify sleep/lid interruption and the wake/reconciliation behavior.

## 3. Windows physical-device checklist

- [ ] Build and launch the Windows target on a Windows 10/11 machine.
- [ ] Check camera discovery, privacy permission, camera-in-use handling, and first-frame startup.
- [ ] Check whether the device has a usable three-axis accelerometer; unsupported hardware must be reported honestly.
- [ ] Test lift / tilt / carry, passerby and lighting false-alarm scenarios, and camera obstruction.
- [ ] Verify the persistent system lifecycle / sleep / lid / shutdown warning behavior that applies to the device.
- [ ] Verify PIN storage through DPAPI and confirm alarm audio routing.

## 4. Android physical-device checklist

- [ ] Install a debug build on a physical Android device and grant requested permissions.
- [ ] Verify linear-acceleration sensor or accelerometer fallback detection.
- [ ] Arm and confirm the persistent WATSafe foreground-service notification appears.
- [ ] Turn the screen off and verify motion monitoring continues while the foreground service remains active.
- [ ] Stop the service from its notification / system controls and confirm WATSafe exits the armed state.
- [ ] Verify successful PIN disarm stops the sensor service.
- [ ] Repeat on a device with aggressive OEM battery management.

## 5. iOS physical-device checklist

- [ ] Build and install on a physical iPhone/iPad; simulator-only success is insufficient for Core Motion validation.
- [ ] Grant Motion & Fitness permission where prompted.
- [ ] Arm in the foreground and verify Core Motion events are received.
- [ ] Lock the screen or switch apps; confirm WATSafe pauses instead of continuing to claim protection.
- [ ] Return to the foreground and verify monitoring resumes only after capability check and successful detector restart.
- [ ] Verify paired-laptop push notifications on a locked iPhone when relay/APNs/Web Push credentials are configured.
- [ ] Confirm the UI communicates the iOS foreground-only limitation clearly.

## 6. Relay / companion physical checklist

- [ ] Configure a permanent HTTPS relay endpoint.
- [ ] Use PostgreSQL or another durable store for cloud deployments; do not rely on ephemeral container storage for pairing data.
- [ ] Configure VAPID / APNs / FCM / webhook credentials as required by the chosen delivery route.
- [ ] Pair a real phone, restart laptop / phone / relay, and confirm the pairing recovers without rescanning.
- [ ] Verify push arrival on a locked phone and tap-through to the correct incident.
- [ ] Check location sharing is opt-in and that no PINs or camera frames appear in relay payloads.

## 7. Known verification gaps

- Platform test suites include mocked native channels; they do not replace the physical-device checklist above.
- PIN lockout persistence and KDF work-factor benchmarking are tracked separately in [Issue #23](https://github.com/jonathannerd/WATSafe/issues/23).
- Review of the extra 0600-protected macOS Application Support copy is tracked in [Issue #26](https://github.com/jonathannerd/WATSafe/issues/26).
- Do not describe a platform as physically verified until the relevant checks have been run and recorded on hardware.
