# WATSafe

**Laptop protection that keeps your phone in the loop.**

WATSafe watches for device movement and camera tampering while protection is armed, sounds a local alarm, and sends alerts to your paired phone. Open an alert to see the affected device on a map, alongside your phone's shared location.

Built with **Flutter, native macOS and Windows integrations, a Dart relay, and PostgreSQL**. The phone companion installs from the browser—no separate native iPhone build is needed to use it.

[![WATSafe CI](https://github.com/jonathannerd/WATSafe/actions/workflows/ci.yml/badge.svg)](https://github.com/jonathannerd/WATSafe/actions/workflows/ci.yml)

[Get started](#get-started) · [Pair your phone](#pair-your-phone) · [How protection works](#how-protection-works) · [Development](#development) · [Troubleshooting](#troubleshooting)

## What you can do

- **Arm your laptop before stepping away.** Camera-based movement detection aims to distinguish laptop movement from people passing nearby. Supported motion sensors provide another detection option.
- **Detect camera tampering.** Sustained obstruction or capture loss while armed triggers an interruption response instead of silently disabling protection.
- **Receive phone alerts.** Install the companion once, enable notifications, and keep the pairing across normal app and relay restarts.
- **Find your devices.** View laptop and phone markers on a detailed OpenStreetMap basemap with location accuracy and freshness.
- **Disarm with your PIN.** A valid PIN stops the alarm.
- **Choose your appearance.** Six themes style the desktop—including its sidebar—and the phone companion.

The phone has two tabs: **Devices** and **Settings**. Alarm notifications open **Devices** with the affected device selected.

> WATSafe is a developing deterrent and alerting tool, not a guarantee against theft. Test protection on your own hardware before relying on it. See [protection limits](#protection-limits).

## Get started

### Requirements

For building from source:

- Git and Flutter. CI currently uses **Flutter 3.47.9**; `pubspec.yaml` requires Flutter `>=3.47.0` and Dart `^3.13.0`.
- The desktop build tools for your target: Xcode for macOS, or Visual Studio with the C++ desktop workload for Windows.
- A webcam for camera protection; motion-sensor support depends on the device.
- An internet connection for remote alerts and map tiles.

Run `flutter doctor` and resolve the checks for the platform you intend to build. Building the Mac app requires Apple's desktop toolchain; installing the **phone web companion** does not require Xcode or an App Store build.

### 1. Get the project

```bash
git clone https://github.com/jonathannerd/WATSafe.git
cd WATSafe
flutter pub get
```

### 2. Connect to the team's relay

Save the permanent service address once:

```bash
dart run tool/dev_launcher.dart --save-permanent-url=https://watsafe-relay.onrender.com --save-only
```

The team's companion is hosted at [watsafe-relay.onrender.com/companion](https://watsafe-relay.onrender.com/companion). You do not need to deploy a server or create a database to use the existing team service.

For your own deployment, substitute your stable HTTPS origin. A temporary tunnel address is unsuitable for a lasting Home Screen installation.

### 3. Launch

**macOS**

```bash
./scripts/run_watsafe.sh
```

The launcher builds the app when needed and reuses the existing bundle on subsequent unchanged launches. After the initial build and relay configuration, you can also open it directly:

```bash
open build/macos/Build/Products/Debug/WATSafe.app
```

**Windows**

From PowerShell in the repository:

```powershell
flutter run -d windows --dart-define=WATSAFE_API_URL=https://watsafe-relay.onrender.com
```

This uses the hosted relay; no separate backend command is needed.

### 4. Complete setup

Choose a device name, create your PIN, and grant the permissions needed for the features you want to use. Pair your phone, check its notification status, then run a supervised protection test before leaving a device unattended.

## Pair your phone

### iPhone

1. On the laptop, select **Pair your phone**.
2. Scan the QR code with your iPhone and open the permanent HTTPS page in Safari.
3. Confirm the laptop name and connect.
4. Copy the Home Screen setup code when prompted.
5. Use **Share → Add to Home Screen → Add**.
6. Open **WATSafe from its Home Screen icon**, enter the setup code if prompted, and enable notifications.
7. Allow location access if you want the phone to appear on the shared map.

Use an iPhone running iOS 16.4 or later for Home Screen Web Push. Complete notification setup inside the installed companion, not just an ordinary browser tab.

### Android

Scan the laptop's QR code in a supported browser such as Chrome, complete pairing, and follow the browser's **Install app** or **Add to Home screen** flow. Enable notifications and optionally share the phone's location.

**Pairing is normally a one-time process.** Reopening either app should reconnect automatically. A sleeping laptop may appear offline without losing its pairing.

Existing permanent-origin installations should update when reopened online. Reinstalling is not the normal update procedure. Moving from an old temporary tunnel to a different permanent domain requires a new installation/pairing on that origin.

## How protection works

1. **Arm:** WATSafe starts the selected detector and registers the protected session with the relay.
2. **Detect:** Movement, sustained camera obstruction, or an interruption can trigger an incident.
3. **Alert:** The laptop attempts a local siren and reports the incident. The relay sends Web Push to the paired phone.
4. **Locate:** Tapping the notification opens the device map with the available location.
5. **Disarm:** Enter the correct PIN on the laptop to stop the alarm.

### Lid closure and unexpected disconnection

Native desktop reporting attempts to send an urgent interruption alert before sleep, independently of the Flutter UI. On macOS, audio handling is separated from emergency reporting so audio teardown does not block the network path.

The relay also watches for an armed laptop that stops responding. Current defaults are an **8-second armed heartbeat**, **30-second timeout**, and **5-second watchdog sweep**. With a running, reachable relay, the fallback can detect a missing host approximately **30–35 seconds after its last heartbeat**. Push delivery adds its own latency; this is not a guaranteed notification deadline.

The fallback reports **“Protected laptop stopped responding.”** It cannot determine whether the cause was theft, lost connectivity, or power loss.

### Location updates

With sharing enabled, the running laptop requests location on launch, resume, pairing, and arming, and approximately every **four minutes** even when disarmed. Supported refresh requests and bounded post-alarm tracking provide additional updates.

The phone shares its **own** location while the companion is open and permitted to do so. Laptop and phone coordinates are kept separate. Accuracy and timestamps matter: **Last known** is not a live position.

### Protection limits

- A fully sleeping or powered-off laptop cannot continue normal camera capture, location updates, or local siren playback. Pre-sleep reporting is best effort; the cloud watchdog is the fallback.
- Remote alerts depend on connectivity, the relay, the push provider, and phone notification settings.
- An in-process watchdog cannot run while its server is suspended or unavailable. Free hosting may introduce cold starts or interruptions.
- Phone PWA location sharing is foreground-only; it is not continuous background GPS tracking.
- Movement detection can produce false positives or miss events. Sensor availability varies by hardware.
- macOS and Windows have native integrations, but a passing shared test suite does not establish identical behavior on every device. Verify each target physically.

## Privacy

- Camera frames are processed locally in memory rather than uploaded to the relay.
- PIN material stays on the device.
- Pairings use authenticated, session-scoped credentials.
- Location access is restricted to the paired session; precise coordinates are omitted from lock-screen notification text.
- Stored location history has a seven-day retention policy and can be deleted through settings.
- Map tiles come from OpenStreetMap infrastructure; loading the map makes requests to that provider.
- Database credentials, private push keys, and tunnel tokens belong in secret storage, never in Git or screenshots.

## Development

### Run with hot reload

On macOS:

```bash
./scripts/run_watsafe.sh --flutter-run
```

In a Flutter run session, press `r` for hot reload, `R` for hot restart, and `q` to quit. A normal restart preserves settings and pairing.

For browser UI development:

```bash
flutter run -d chrome --dart-define=WATSAFE_API_URL=https://watsafe-relay.onrender.com
```

The Flutter web target and the relay-served phone companion are separate interfaces. To change the installed phone experience, inspect `lib/relay/pwa_assets.dart`; a Flutter web build alone does not update the hosted companion.

### Project structure

| Path | Purpose |
|---|---|
| `lib/core/` | Alarm state, contracts, and shared models |
| `lib/features/` | Flutter screens and user flows |
| `lib/services/` | Pairing, location, notifications, storage, and relay configuration |
| `lib/platform/` | Platform detector adapters |
| `lib/relay/` | Relay server, phone PWA, and Web Push |
| `macos/`, `windows/` | Native desktop bridges |
| `android/`, `ios/` | Native mobile targets |
| `backend/server.dart` | Standalone relay entry point |
| `tool/`, `scripts/` | Launcher and deployment verification |
| `test/` | Automated regression tests |

### Checks before a pull request

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
dart analyze tool/ backend/ lib/
flutter test
```

Build affected targets on the appropriate machine:

```bash
flutter build web
flutter build macos --debug
```

For Windows, use `flutter build windows` on Windows. Automated tests do not replace a real locked-phone notification test or a physical lid-close test.

### Working together

Start a task from an up-to-date `main` with a clean working tree:

```bash
git switch main
git pull --ff-only origin main
git switch -c feat/your-change
```

Make and verify your changes, commit the intended files, and push your branch:

```bash
git push -u origin feat/your-change
```

Open a pull request into `main` and wait for CI and review. Commit or stash unfinished work before switching branches or pulling. If Git reports a conflict or divergence, resolve it without discarding teammates' work or force-pushing shared history.

### Preview a fresh install

Debug builds provide **Preview onboarding** and **Reset demo and restart onboarding** under the advanced settings.

Preview preserves data. Reset clears this installation's setup and revokes its pairing, so use it only when you intend to pair again.

## Hosting your own relay

The deployment consists of a stable HTTPS web service and durable PostgreSQL storage. The team's deployment uses **Render and Neon PostgreSQL**; Aiven is an optional supported provider, not a prerequisite.

1. Deploy the root [Render blueprint](render.yaml) and [Dockerfile](Dockerfile).
2. Set `DATABASE_URL` to your PostgreSQL connection URI through the host's secret settings. For Aiven, the alternative `AIVEN_DATABASE_URL` is supported.
3. Retain the same database and VAPID keys across deployments to preserve pairing and push subscriptions.
4. Verify persistence before switching users to the new origin.

Use your actual service URL in place of `YOUR-SERVICE`:

```bash
dart run tool/verify_deployment.dart --require-postgres --phase=before-restart https://YOUR-SERVICE.onrender.com
```

Restart or redeploy that relay, then run:

```bash
dart run tool/verify_deployment.dart --require-postgres --phase=after-restart --save https://YOUR-SERVICE.onrender.com
```

The blueprint does not create a database for you. Container-local files are not a substitute for durable cloud storage. Health responses may use the legacy label `aiven_postgres` for the PostgreSQL adapter even when the database is Neon.

See [backend documentation](backend/README.md) for environment variables and endpoints. Verify the current hosting plan's availability and resource limits before depending on it for time-sensitive alerts.

## Troubleshooting

| Problem | What to check |
|---|---|
| Phone is paired but receives no alerts | Open the installed companion, check **Settings → Connection**, allow notifications, and use **Repair notifications** if offered. Check the phone's notification/Focus settings. |
| Old bookmark opens a tunnel error page | Install from the permanent HTTPS origin. An expired temporary hostname cannot be repaired by restarting the laptop. |
| Map is blank | Check connectivity, retry map loading, and reopen the companion online to receive updated assets. Markers alone do not prove map tiles loaded. |
| Map position looks old | Check the timestamp, location permission, sharing setting, and whether the source device is awake and online. |
| Alarm only occurs after reopening the lid | Confirm the updated desktop build and relay are in use. Repeat the closed-lid test below and report timing; waking up is not proof of successful pre-sleep delivery. |
| macOS asks for Keychain access after a rebuild | A changed app signature can require renewed permission. The normal launcher reuses an unchanged bundle; hot-reload builds may prompt again. |
| SDK constraint error | Compare `flutter --version` with `pubspec.yaml` and the pinned CI toolchain. |
| App reconnects slowly after inactivity | The relay or database may be waking up. Check service health before resetting or re-pairing devices. |

### A useful hardware test

With your phone paired and notifications enabled:

1. Arm the laptop, lock the phone, and close the laptop.
2. Keep the lid closed for at least 45 seconds and record notification timing.
3. Reopen the laptop, check for duplicate incidents, and disarm with your PIN.
4. Separately test camera covering and loss of laptop network access.
5. Repeat after important native or notification changes.

When reporting a problem, include device/OS, app commit, steps, expected result, actual result, and elapsed time. Remove credentials and precise location data from logs.
