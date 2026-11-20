# WATSafe Platform Capabilities & Limitations

This document distinguishes what is implemented in source, what automated tests exercise, and what still needs validation on physical hardware. A mocked platform-channel test or successful compile does not prove that an OS permission, sensor, camera, siren, or background service behaves correctly on every device.

## 1. Capability matrix

| Capability | macOS | Windows | Android | iOS | Web |
|---|---|---|---|---|---|
| Shared Flutter UI and alarm state machine | Implemented | Implemented | Implemented | Implemented | Implemented |
| PIN storage | Keychain; 0700 directory / 0600 file only as fallback | Windows DPAPI | Android Keystore AES-256-GCM | iOS Keychain | Browser-restricted local fallback |
| Camera scene-motion detection | AVFoundation + shared Dart motion analyzer | Media Foundation native capture and motion pipeline | Not applicable | Not applicable | Browser camera APIs where supported |
| Motion sensors | No public built-in Mac laptop accelerometer API used | Optional WinRT / Sensor API accelerometer | SensorManager linear-acceleration or accelerometer fallback | Core Motion while foregrounded | Not applicable |
| Background motion monitoring | Native sleep/lid lifecycle reporting; no capture while asleep | Native sleep/lid/shutdown lifecycle reporting; camera capture pauses during sleep | User-visible special-use foreground service | Foreground only; pauses on background/screen lock | Browser lifecycle and permissions apply |
| Local alarm audio | AVAudioPlayer | Native Windows audio bridge | Platform audio adapter | AVAudioPlayer / AVAudioSession | Browser audio policy applies |
| Pairing and remote alerts | Configurable HTTPS relay | Configurable HTTPS relay | Companion client / relay | Companion client / relay | Phone companion PWA |

The matrix describes code in the repository. It does not mean every optional integration is configured by default or verified on physical hardware.

## 2. Detection and lifecycle behavior

### macOS

- Camera frames are captured through AVFoundation and processed locally.
- The shared CameraMotionAnalyzer downsamples frames to a compact grayscale grid and estimates camera ego-motion using landmark anchoring, Lucas-Kanade optical flow, illumination normalization, and temporal filtering.
- Camera images are not intended to be saved or uploaded.
- The native lifecycle bridge reports sleep, lid/power, and termination-related events. A sleeping or powered-off Mac cannot continue live camera capture or play its local siren.

### Windows

- Webcam capture uses Windows Media Foundation (MFEnumDeviceSources and IMFSourceReader) on a native worker thread.
- The native motion pipeline samples supported camera pixel formats, accounts for row pitch, and reports camera obstruction / low-light conditions.
- An optional hardware accelerometer uses WinRT / Windows Sensor APIs when suitable hardware exists. Many conventional laptops do not expose an integrated three-axis accelerometer; in that case the adapter reports unsupported and the app can use webcam detection when available.
- Native lifecycle hooks cover lid state, sleep/wake, shutdown/logoff, and optional input-interaction monitoring. Camera capture itself cannot run while Windows is asleep or powered off.

### Android

- The native adapter queries SensorManager for TYPE_LINEAR_ACCELERATION, falling back to TYPE_ACCELEROMETER with gravity filtering.
- Monitoring runs on a sensor thread and uses a user-visible WatSafeForegroundService with the declared special-use foreground-service type and persistent notification.
- If the service stops, the native bridge emits a failure event so the controller can leave the armed state.
- Background execution remains subject to Android version, permission, battery-management, and device-manufacturer policies. Validate on physical devices, including screen-off behavior and service termination.

### iOS

- Motion detection uses CMMotionManager through the native Core Motion bridge.
- On iOS/iPadOS 27.2 and later, readiness checks use CMMotionManager.authorizationStatus and request authorization by starting a short-lived sensor probe when the status is not determined. A denied or restricted status prevents arming.
- Earlier supported releases do not expose this separate live-sensor authorization status; WATSafe reports it as not applicable and validates sensor startup before claiming monitoring has started.
- Live monitoring is deliberately foreground-only. When iOS backgrounds or suspends the app (including screen lock), the bridge stops motion updates and emits a lifecycle pause; the controller must not continue displaying Protected while monitoring is inactive.
- Returning to the foreground triggers a capability check and a guarded monitoring restart. iOS does not provide indefinite background accelerometer capture for this app.

### Web

- Browser camera and audio access depend on browser support, user permission, autoplay policy, and page lifecycle.
- A browser tab being hidden, suspended, or closed cannot be treated as equivalent to a native always-on foreground service.

## 3. PIN and storage behavior

- PINs are validated as 6–12 digits and stored as salted PBKDF2-HMAC-SHA256 verifier records, not as plaintext PINs.
- New production PIN records target 600,000 PBKDF2-HMAC-SHA256 iterations. Existing weaker records remain readable and are re-derived at the configured target after a successful PIN verification.
- Failed-attempt count and lockout deadline are optional members of the same secure PIN record, so older records deserialize with zero attempts and no active lockout. Lockout metadata is persisted after failed attempts and restored before PIN checks.
- Secure-storage write failures are surfaced in the PIN verification result. Failed attempts remain enforced in memory; a correct PIN can still disarm after the lockout expires, but the UI receives a warning when the reset or verifier upgrade could not be saved.
- On macOS, Keychain is the primary PIN and secure-secret store. The protected Application Support file is written only when the Keychain write fails; an existing fallback is migrated back to Keychain after a successful Keychain write. The fallback directory is restricted to 0700 and files to 0600.
- The 600,000-iteration target must be benchmarked on real supported devices before release. See the on-device KDF benchmark in [docs/testing.md](testing.md); a derivation taking more than one second should trigger a work-factor review.

## 4. Pairing, location, and remote alerts

- ConfigurableRemoteNotificationService supports pairing, reconnection, authenticated relay requests, and companion alert/location flows.
- The service is not equivalent to a configured production deployment: a relay URL, valid host/companion pairing, push-provider configuration, and durable server storage may still be required.
- The relay supports local file storage and PostgreSQL-backed persistence. Cloud deployments should use a durable database and keep database / push credentials in environment secrets.
- Phone location sharing is opt-in. Camera frames and PIN material are not part of relay payloads.

## 5. Verification status and known limits

Automated tests cover controller transitions, mocked native channels, camera-frame sampling / synthetic motion scenarios, relay request behavior, pairing, and notification flows. CI runs formatting, static analysis, and automated tests.

Physical-device verification is still required for:
- macOS Keychain behavior, camera permission prompts, sleep/lid interruption, and local siren routing;
- Windows webcam/accelerometer availability, camera-in-use errors, lid/sleep reporting, and audio routing;
- Android sensor availability, foreground-service notification, screen-off monitoring, OEM battery restrictions, and service-stop handling;
- iPhone/iPad Core Motion permission, screen-lock pause, foreground resume, and real notification delivery.

WATSafe cannot prevent a user or operating system from powering off, force-quitting, muting, or physically disconnecting a device. A laptop that is asleep or powered off cannot keep sampling its camera or playing its local siren; the relay watchdog can only act on information already received and while the relay itself is available.
