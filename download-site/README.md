# WATSafe download website

A small, dependency-free static download site.

## Preview locally

From the repository root:

    python3 -m http.server 8090 --directory download-site

Then open http://localhost:8090.

The download cards read the latest published GitHub Release from the public GitHub API. Until a release exists, the site intentionally shows a clear "not published yet" state rather than a broken or invented download.

## Hosting

The `.github/workflows/deploy-download-site.yml` workflow publishes this site to GitHub Pages and builds the Flutter web companion under `/companion/`.

In repository settings, enable **Settings → Pages → Build and deployment → Source: GitHub Actions**. The workflow runs on pushes to `main` that change the site, Flutter app, or deployment workflow. It can also be run manually from the Actions tab for a branch preview.

The companion is a PWA and must be served over HTTPS (GitHub Pages provides HTTPS). Remote pairing and push alerts still require a configured HTTPS relay. A static Pages deployment does not deploy the relay service.

## Publishing application downloads

The `.github/workflows/publish-downloads.yml` workflow runs when a version tag matching `v*` is pushed. It builds:
- `WATSafe-macOS-arm64.zip` — Apple Silicon macOS application bundle.
- `WATSafe-macOS-x64.zip` — Intel macOS application bundle.

Both Mac packages are not Developer ID signed/notarized by this workflow.
- `WATSafe-Windows-x64.zip` — portable Windows x64 release folder (not Authenticode signed).
- `WATSafe-Android-preview.apk` — debug-signed Android preview APK for testing, not a Play Store release.

The website finds these exact filenames in the latest GitHub Release and exposes only the downloads that exist. iPhone/iPad use the web companion; an IPA/TestFlight/App Store release requires separate Apple signing and distribution setup.

Before publishing public production downloads, configure Apple Developer ID signing and notarization, Windows code signing, and a production Android signing key. The Android package generated here uses the repository's existing debug signing configuration and is explicitly a preview build.

## Download verification

Each release also includes `SHA256SUMS.txt`; the page displays a checksum link when that asset is present. Verify a download before installing:

    shasum -a 256 -c SHA256SUMS.txt

The checksums prove file integrity against the published release manifest. They do not establish publisher identity or code-signing trust.
