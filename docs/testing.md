# Testing Guide & Hardware Verification Checklist

WATSafe combines automated unit/widget tests (which run on every commit and in CI without requiring physical sensors) and a manual hardware verification checklist for physical device adapters.

---

## 1. Automated Tests

Run all automated checks from the repository root:

```bash
# 1. Verify Dart formatting
dart format --output=none --set-exit-if-changed .

# 2. Run static analysis
flutter analyze

# 3. Run unit and widget test suite
flutter test
```

### What the Automated Suite Covers
- **State Machine & Session Isolation (`test/alarm_controller_test.dart`):**
  - First-run PIN creation validation (rejects `< 6` digits or mismatched confirmation) and PBKDF2-HMAC-SHA256 verification.
  - Requiring the current PIN before allowing a PIN change.
  - Refusing to arm when the selected detector is `unavailable`, `permissionRequired`, or `notImplemented` (enters `AlarmStatus.unavailable` instead of pretending to protect).
  - Arming countdown transition (`disarmed` -> `arming` -> `armed`) and detector calibration startup.
  - Single-incident deduplication: multiple rapid detector events during a single armed session create only **one** active incident and start the alarm audio once.
  - Fault isolation: a failure in remote notification dispatch does not stop the local siren or prevent PIN disarming.
  - Wrong PIN attempts keep the alarm active and apply stepped lockout backoff after 3 failed attempts; the correct PIN stops the siren and returns to `disarmed`.
  - Separate 5-second Test Alarm flow creates an incident explicitly marked `isTest: true` and auto-stops after 5 seconds.
- **UI & Navigation Flows (`test/widget_test.dart`):**
  - First-run onboarding screen and 6-digit PIN setup.
  - Protection Dashboard rendering with detector status cards and honest capability badges.
  - Triggering and stopping the 5-second Test Alarm from the dashboard.
  - Verifying `[TEST]` badge visibility in Incident History.
  - Verifying the honest `Not configured` state on the Paired Devices screen.

---

## 2. Manual Hardware Verification Checklist (macOS)

Run the macOS desktop application locally:

```bash
flutter run -d macos
```

Or build and launch the debug app bundle directly:

```bash
flutter build macos --debug
open build/macos/Build/Products/Debug/WATSafe.app
```

### Checklist

- [ ] **1. First-Run PIN Setup**
  - Launch the app on a clean profile.
  - Attempt to enter a 4-digit PIN -> verify validation error requires 6–12 digits.
  - Enter a 6-digit PIN and confirm -> verify transition to the Protection Dashboard.
- [ ] **2. Camera Permission Request & Status Reporting**
  - Click **Grant Camera Permission** (or **Refresh**) on the macOS Webcam Scene-Motion card.
  - Verify macOS prompts: *"WATSafe uses the built-in camera to detect physical movement or tampering in the camera view while the device alarm is armed. Video frames are analyzed locally in memory and are never saved or uploaded."*
  - **If Granted:** Verify detector badge changes to **Ready (Calibrated on Arm)**.
  - **If Denied:** Verify detector badge shows **Permission Required** with guidance to open `System Settings > Privacy & Security > Camera`, and verify clicking **Arm Device** refuses to arm.
- [ ] **3. Arming Countdown & Calibration Window**
  - With camera permission granted, click **Arm Device**.
  - Verify the visible countdown banner ticks down (`10s` default, configurable in Settings).
  - Verify clicking **Cancel Arming** during the countdown aborts cleanly without sounding the alarm.
  - Let the countdown complete -> verify status transitions to **Armed & Monitoring** and the macOS camera indicator light turns green.
- [ ] **4. Scene-Motion Alarm Trigger**
  - Wait 2 seconds after arming finishes so baseline calibration completes.
  - Wave a hand in front of the webcam or tilt the laptop lid.
  - Verify the full-screen **ALARM TRIGGERED** overlay appears immediately, local siren audio loops at the configured volume, and a single `Real Trigger` incident is recorded.
- [ ] **5. Wrong PIN Lockout & Correct PIN Disarm**
  - While alarming, enter an incorrect 6-digit PIN 3 times.
  - Verify the alarm continues sounding and a temporary lockout countdown is displayed.
  - Enter the correct 6-digit PIN -> verify the siren stops immediately, the macOS camera indicator light turns off, and the incident is marked **Disarmed with PIN** in the Incidents tab.
- [ ] **6. Low-Light / Covered Lens Warning**
  - Cover the webcam lens completely while armed.
  - Verify the dashboard surfaces a degraded-input warning explaining that the camera view is too dark (`meanLuma < 8.0`) for reliable motion detection.
- [ ] **7. Independent 5-Second Test Alarm**
  - Click **Test Alarm (5s max)** on the Dashboard.
  - Verify the siren plays even if no camera is available or camera permission is denied.
  - Verify the test alarm stops automatically after 5 seconds (or immediately when clicking **Stop Test Alarm Now**) and logs an incident labeled **`[TEST]`** in the Incidents tab.
- [ ] **8. Honest Unconfigured & Limitations Messaging**
  - Open **Paired Devices** -> verify the banner clearly states **Not configured** and does not list fake paired phones.
  - Open **Settings** -> verify the Operating System & Audio Honesty Notice clearly explains that WATSafe does not override OS lock screens, hardware mute keys, or forced shutdown.
