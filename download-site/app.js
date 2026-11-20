(() => {
  const REPO = "jonathannerd/WATSafe";
  const RELEASE_ENDPOINT = `https://api.github.com/repos/${REPO}/releases/latest`;
  const ASSETS = {
    "macos-arm64": "WATSafe-macOS-arm64.zip",
    "macos-x64": "WATSafe-macOS-x64.zip",
    windows: "WATSafe-Windows-x64.zip",
    android: "WATSafe-Android-preview.apk"
  };

  const byPlatform = (name) =>
    document.querySelector(`[data-platform="${name}"]`);

  function setDownload(platform, asset, version) {
    const cardName = platform.startsWith("macos-") ? "macos" : platform;
    const card = byPlatform(cardName);
    if (!card || !asset) return false;
    const link = card.querySelector(`[data-download-link="${platform}"]`);
    const unavailable = card.querySelector("[data-unavailable]");
    const badge = card.querySelector("[data-status]");
    if (!link) return false;
    link.href = asset.browser_download_url;
    link.hidden = false;
    if (unavailable) unavailable.hidden = true;
    if (badge) {
      badge.textContent = platform === "android" ? "Preview build" : version;
      badge.classList.toggle("badge-preview", platform === "android");
    }
    return true;
  }

  function showStatus(message, state = "info") {
    const status = document.getElementById("release-status");
    if (!status) return;
    status.replaceChildren();
    const icon = document.createElement("span");
    icon.className = state === "ready" ? "status-spinner done" : "status-spinner";
    icon.textContent = state === "ready" ? "✓" : "";
    status.append(icon, document.createTextNode(message));
  }

  async function loadRelease() {
    const versionText = document.getElementById("release-version");
    try {
      const response = await fetch(RELEASE_ENDPOINT, {
        headers: { Accept: "application/vnd.github+json" },
        cache: "no-store"
      });
      if (response.status === 404) {
        showStatus("The first downloadable release is being prepared. Check back soon.");
        if (versionText) versionText.textContent = "No published release yet";
        return;
      }
      if (!response.ok) throw new Error(`GitHub returned ${response.status}`);
      const release = await response.json();
      const assets = new Map((release.assets || []).map(asset => [asset.name, asset]));
      const checksumAsset = assets.get("SHA256SUMS.txt");
      const checksumLink = document.getElementById("checksums-link");
      if (checksumAsset && checksumLink) {
        checksumLink.href = checksumAsset.browser_download_url;
        checksumLink.hidden = false;
      }
      let found = 0;
      for (const [platform, filename] of Object.entries(ASSETS)) {
        if (setDownload(platform, assets.get(filename), release.tag_name || release.name || "Latest")) {
          found += 1;
        }
      }
      const date = release.published_at
        ? new Date(release.published_at).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" })
        : "";
      if (versionText) versionText.textContent = `${release.tag_name || release.name || "Latest release"}${date ? " · Published " + date : ""}`;
      showStatus(
        found
          ? `Latest release loaded. ${found} download option${found === 1 ? "" : "s"} available.`
          : "A release exists, but downloadable packages have not been attached yet.",
        found ? "ready" : "info"
      );
    } catch (error) {
      showStatus("Could not check GitHub Releases right now. You can still view all releases below.");
      if (versionText) versionText.textContent = "Release status unavailable";
      console.warn("WATSafe release lookup failed:", error);
    }
  }

  async function checkCompanionAvailability() {
    const card = byPlatform("companion");
    if (!card) return;
    const link = card.querySelector("[data-companion-link]");
    const unavailable = card.querySelector("[data-companion-unavailable]");
    try {
      const response = await fetch(new URL("./companion/", window.location.href), {
        method: "HEAD",
        cache: "no-store"
      });
      if (!response.ok) throw new Error("Companion route is not deployed");
      if (link) link.hidden = false;
      if (unavailable) unavailable.hidden = true;
    } catch (_) {
      if (link) link.hidden = true;
      if (unavailable) unavailable.hidden = false;
    }
  }

  const year = document.getElementById("current-year");
  if (year) year.textContent = String(new Date().getFullYear());
  loadRelease();
  checkCompanionAvailability();
})();
