<div align="center">

# WATSafe

**A laptop protection app with a phone companion.**

![Flutter](https://img.shields.io/badge/Flutter-desktop-02569B?logo=flutter&logoColor=white)
![Desktop](https://img.shields.io/badge/Desktop-macOS%20%7C%20Windows-334155)
![Phone](https://img.shields.io/badge/Companion-iPhone%20%7C%20Android-059669)

</div>

WATSafe is built for the moment you step away from your laptop in a library, café, or shared workspace. Arm it before you leave. If the laptop moves or its camera monitoring is interrupted, WATSafe can sound a siren and alert your phone.

## Demo

[![WATSafe animated demo](assets/demo/watsafe-demo.webp)](assets/demo/WATSafe.mp4?raw=true)

## Highlights

- **Movement detection** looks for signs the laptop itself moved and aims to ignore people walking past.
- **Camera tamper detection** responds to sustained obstruction or loss of camera capture. Camera frames are processed on the laptop.
- **Lid-close and connection alerts** can warn you before an armed laptop goes to sleep or when it stops checking in. A sleeping laptop cannot keep playing its siren.
- **Phone notifications** open the affected device on the map. Pair once by scanning a QR code with the iPhone or Android web companion.
- **Device map** shows reported laptop and phone locations with timestamps and an estimate of accuracy.
- **PIN and themes** let you disarm protection with your PIN and choose from six themes on desktop and phone.
- **Activity search and reports** help filter incidents and copy a CSV event history.
- **Local Safe Zones** can notify the protected device when it enters or leaves a saved area while WATSafe is running.
- **Lost-device refresh** lets a paired phone request an updated position from an online protected laptop when location sharing is enabled.

## How it works

```mermaid
flowchart LR
    A["Pair your phone"] --> B["Arm your laptop"]
    B --> C["Get a phone alert"]
    C --> D["Check the device map"]
```

## Download WATSafe

The responsive download website lives in [`download-site/`](download-site/). It reads published release assets from GitHub and only shows download buttons for files that actually exist.

Preview the website locally:

    python3 -m http.server 8090 --directory download-site

Open http://localhost:8090.

After enabling GitHub Pages with **Settings → Pages → Source: GitHub Actions**, the `Deploy WATSafe download site` workflow publishes the site and the Flutter web phone companion. The expected project Pages address is `https://jonathannerd.github.io/WATSafe/` unless a custom domain is configured.

To create downloadable packages after local testing, push a version tag such as `v0.1.0`. The `Publish WATSafe downloads` workflow attaches separate Apple Silicon and Intel macOS ZIPs, a Windows x64 ZIP, an Android preview APK, and SHA-256 checksums to the GitHub Release. See [download-site/README.md](download-site/README.md) for platform signing and distribution limitations.

## Built with

**Flutter** for the desktop app, native **Swift** and **C++** for desktop integrations, and a **Dart** relay with **PostgreSQL** for pairing and alerts. The phone companion uses **Web Push** and displays **OpenStreetMap** tiles.
