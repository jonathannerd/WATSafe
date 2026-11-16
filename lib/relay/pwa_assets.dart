import 'dart:convert';
import 'dart:typed_data';

/// Embedded PWA icons, Web App Manifest, Service Worker, and guided iPhone /
/// Android Web Companion HTML served directly by `WatSafeRelayServer`.
class CompanionPwaAssets {
  const CompanionPwaAssets._();

  static final Uint8List icon192Png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAMAAAADACAYAAABS3GwHAAADbElEQVR42u3cO05DMRRFUQ8CIVEg0cBwmSUVHRI1SBkAnyi27/VZxW4DzzkrQfDIuLt/+JJSGw5BAEgASABIAEgASABIAEgASABIAEgASABIAEgASABIAFzb49OzgooHYASqAGIYvpIhDMNXMoRh+EqGMIxfyQiG8SsZwTB+JSMAQAAYv1IRACAAjF+pCAAQAMavVAQACAAABAAAAsD4lYUAAAEAgAAAQAAAIAAAEAAACAAABAAAs3p7fbnkLACIGPp/c3YARAwdDAAMHQwAjB0KAAwdDAAMHQwADB0MAAwfBAAAAAAAAAAAAAAAAAAAAACaAjj9+wcAgClDAQCAkkNxvQDEAPDXbgAiALixD4AIAO6p731mAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADGDwAAAAAAAAAAAAAAAADM7fPj/cecGQBHPpm/DX8nBAAAKDP8HRAAAKDk+FchAACAsuNfgQAAAEqPfzYCAAAAAAAAKo9/JgIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADcCgEAAAAAAIDboQEAwD/EAACAf4kEoB2A6ghSzwuAQ5/Q7p8IAQAA0zA4LwC2PKHJnxDX/awAOPBVzTkB4F3AGQHgXcD5AOBdwNkA4F3AuQDgXcCZAACBswAAAGcBAATOAICpT/5JCE69fgCMIPq6AfBjQPQ1A+DVMPp6ATCK6OsEwDiikQNgJNE/5gGwYSiVx3LiNQHg1dKrPwBGY/wAGI/xA2BExg+AMbnHCYDs36Kk/cYHAMMyfgAMzPgBiEVg/ADEIjB+AGIRGD8AsQiMH4D2CK4Z4+qvBwAAZUZp/ADEIjB+AGIRGD8AsQiMH4BYBMYPQCwC4wcAAuMHAALjBwAC4wcAAuMHAALjBwAEwwfA3woEgE+bEABRCJwZALEInBUAsQicEQCxCJwNAJEQnAUAEgASABIAEgBSDwAQqOP4ARAAAAgAAAQABMoaPwAC4JYPBoE6jR8AAXDrB4RAXcYPgACY8aAQqMP4pwKAQNXHPx0ABKo8/iUAQFDF4S8HAIIqDX8bABBUYfjbAQBh8BUqA0ACQAJAAkACQAJAAkACQAJAAkACQAJAAkACQAJAAkACQPpL3zyVBghoEjZtAAAAAElFTkSuQmCC',
  );

  static final Uint8List icon512Png = base64Decode(
    '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',
  );

  static final Uint8List appleTouchIcon180Png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAALQAAAC0CAYAAAA9zQYyAAADSUlEQVR42u3dMU4DMRRF0VkEQqJAooHlsksqOiRqaKkSELHHfu8Ut0Xy92GUSZzMcXf/8CWldBiCgJaAloCWgBbQEtAS0BLQEtACWgJaAloCWgJaQE/q8elZgdWAttmAR4C2qZoF+4BZSagPmJWE+gBZSbCBFtAwa1XUB8xKQn3ArCTUQAtomLUqaqAFNNACWtoBtI3QSqiBFtBAC2gJaAENtIAGWkADLaAloDfr7fXlV5kV0FvC/WtAA70lXNCBrsHbihzoErgt0IEuh5sGHWhwo6ADDXMUaqCBBhpoAQ000EAD/RMK0EBXfJIHNNCng7AmoLfc/KYPioAOAu0MCtDbgna8FegI0M5tAw000EDbMKCBBtp8gAYaaKCBBhpooIG2YUADDTTQQAMNNNBAAw000EDbMPMBGmiggQYaaKCBBhro631+vF8MaKC32LBrkM+ADTTQUzDPQg000NMwz0ANNNBTMY9GDTTQ0zGPRA000KdgHoUaaKCBBhpooIHedsNGYR6BGmiggQYaaKCBBhpooIEGGmjvcgANNNBAAw000M5yOMsBtNN2QAMNNNBRDw1qO+DvoUFAR32nEGigo771DTTQlb/JAbQHb0ZhBnoh0K7SOTMB2lU6ah5AQx01B6CBBjoVNNT7rx9ooIFOBt2MOmHdQN9gYxNQp6wZaFfpqPUCDXXUOoEuf+mRtkagi1Enrg3o0o1P/UcFetDmrwwgbT1Al1/Rkl9GAV0GIf1GF+giEA3v2gBdAqPl00+gC26qkm8CgS5D0oQZ6HAsbZiBDkbTiBnoUDytmIEORNSMGegwTO2YgQ5CDTPQMahhBjoGNcxAx6CGGehtUF+CN+JvAg30KahhBjoGNcxAx6CGGWioCx+hAXQw6sbZAh2KunWuQAeibp4p0GGo2+cJdBBqswQ6BrUZAu2nbYEGeiXUZgV0DGozAjoGtdkAHYPaTICOQW0WQAtooAU00AIaaAEtrQwaaq2CGWgBDbSAlnYCDbVWwAy0gIZaq2K+OWiodSbmIaCh1lmYgRbQYGtFyFNAQ62ZmKeAhlqzME8DDTbIs5oKGnCAo0FLQEtAC2gJaAloCWgJaAEtAS0BLQEtAS2gJaAloKV/9A1wcyE4k8ZT9gAAAABJRU5ErkJggg==',
  );

  static final Uint8List favicon64Png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAABH0lEQVR42u3bvQrCMBSG4VyECA6Ci71c79LJTXDWuQFp2p6fL+k7nNHS76EkNee0nM6X75GrAAAAAAAAsFDX273LMgHoNXwrQhk5fAtCGT38EgIAAAAAQArA8zHNaliAOuja6gZgb1BvGFeA6PBbECQBrH4vD+C1fsgCKO4cAAAAAAAAKAF83q9ZHQqgDt+KMATAv/AtCAAAAACLINtgL3+HvV+CpAAi3galj8S8nwL5M0Hvp8DiumHH4tYIVtdLA7A+E+yiMWJx49ZrSnhnaE8AjwU1pTW2JYjXbiLVG8zYSlO7wy3BvN8m09vja1tjQ84HRLfEJQckMsLLTYhEh2dERnVIKio8U2IAAAAA4/J8MMEnM3w0BQAAAAAAQFU/pxCv2IampgYAAAAASUVORK5CYII=',
  );

  static String buildWebManifestJson() {
    return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'id': '/companion',
      'name': 'WATSafe Phone Companion',
      'short_name': 'WATSafe',
      'description': 'Receive protected laptop alarm notifications and view device location.',
      'start_url': '/companion?source=homescreen',
      'scope': '/',
      'display': 'standalone',
      'orientation': 'portrait',
      'background_color': '#141619',
      'theme_color': '#141619',
      'icons': <Map<String, String>>[
        <String, String>{
          'src': '/icons/icon-192.png',
          'sizes': '192x192',
          'type': 'image/png',
          'purpose': 'any',
        },
        <String, String>{
          'src': '/icons/icon-192.png',
          'sizes': '192x192',
          'type': 'image/png',
          'purpose': 'maskable',
        },
        <String, String>{
          'src': '/icons/icon-512.png',
          'sizes': '512x512',
          'type': 'image/png',
          'purpose': 'any',
        },
        <String, String>{
          'src': '/icons/icon-512.png',
          'sizes': '512x512',
          'type': 'image/png',
          'purpose': 'maskable',
        },
      ],
    });
  }

  static const String serviceWorkerJs = r'''
const SHELL_CACHE = 'watsafe-shell-2026.11.16-v2';
const SHELL_URLS = [
  '/companion',
  '/manifest.webmanifest',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
  '/icons/apple-touch-icon.png',
  '/favicon.png'
];
const IDB_NAME = 'watsafe_companion_v2';
const IDB_STORE = 'kv';
const IDB_STATE_KEY = 'state';

function isAuthenticWatSafeResponse(res) {
  return Boolean(res && res.ok && res.headers && res.headers.get('x-watsafe-companion') === '1');
}

function urlBase64ToUint8ArraySw(base64String) {
  const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
  const rawData = atob(base64);
  const outputArray = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i);
  }
  return outputArray;
}

function arrayBufferToBase64UrlSw(buffer) {
  if (!buffer) return '';
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function readIdbStateSw() {
  return new Promise((resolve) => {
    if (typeof indexedDB === 'undefined') {
      resolve(null);
      return;
    }
    try {
      const req = indexedDB.open(IDB_NAME, 1);
      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains(IDB_STORE)) {
          db.createObjectStore(IDB_STORE);
        }
      };
      req.onsuccess = () => {
        try {
          const db = req.result;
          const tx = db.transaction(IDB_STORE, 'readonly');
          const getReq = tx.objectStore(IDB_STORE).get(IDB_STATE_KEY);
          getReq.onsuccess = () => {
            db.close();
            resolve(getReq.result || null);
          };
          getReq.onerror = () => {
            db.close();
            resolve(null);
          };
        } catch (_) {
          resolve(null);
        }
      };
      req.onerror = () => resolve(null);
    } catch (_) {
      resolve(null);
    }
  });
}

function writeIdbStateSw(nextState) {
  return new Promise((resolve) => {
    if (typeof indexedDB === 'undefined' || !nextState) {
      resolve();
      return;
    }
    try {
      const req = indexedDB.open(IDB_NAME, 1);
      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains(IDB_STORE)) {
          db.createObjectStore(IDB_STORE);
        }
      };
      req.onsuccess = () => {
        try {
          const db = req.result;
          const tx = db.transaction(IDB_STORE, 'readwrite');
          tx.objectStore(IDB_STORE).put(nextState, IDB_STATE_KEY);
          tx.oncomplete = () => {
            db.close();
            resolve();
          };
          tx.onerror = () => {
            db.close();
            resolve();
          };
        } catch (_) {
          resolve();
        }
      };
      req.onerror = () => resolve();
    } catch (_) {
      resolve();
    }
  });
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      try {
        const cache = await caches.open(SHELL_CACHE);
        await Promise.all(
          SHELL_URLS.map(async (assetUrl) => {
            try {
              const res = await fetch(assetUrl, { cache: 'reload' });
              if (isAuthenticWatSafeResponse(res)) {
                await cache.put(assetUrl, res.clone());
              }
            } catch (_) {}
          })
        );
      } catch (_) {}
      await self.skipWaiting();
    })()
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      try {
        const keys = await caches.keys();
        await Promise.all(
          keys.map((key) => {
            if (key.indexOf('watsafe-shell-') === 0 && key !== SHELL_CACHE) {
              return caches.delete(key);
            }
            return Promise.resolve(false);
          })
        );
      } catch (_) {}
      await self.clients.claim();
      const windowClients = await self.clients.matchAll({
        type: 'window',
        includeUncontrolled: true
      });
      for (const client of windowClients) {
        client.postMessage({ type: 'SW_ACTIVATED', version: SHELL_CACHE });
      }
    })()
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (!req || req.method !== 'GET') return;
  let url;
  try {
    url = new URL(req.url);
  } catch (_) {
    return;
  }
  if (url.origin !== self.location.origin) return;

  const isNavigation =
    req.mode === 'navigate' ||
    url.pathname === '/' ||
    url.pathname === '/pair' ||
    url.pathname === '/companion';

  if (isNavigation) {
    event.respondWith(
      (async () => {
        try {
          const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
          const timer = controller ? setTimeout(() => controller.abort(), 4000) : null;
          const netRes = await fetch(
            req,
            controller ? { cache: 'no-store', signal: controller.signal } : { cache: 'no-store' }
          );
          if (timer) clearTimeout(timer);
          // Only render network HTML if it carries WATSafe's authentic header.
          // Never render white Cloudflare 530 / 1033 ("Was this helpful?") or proxy 502 error pages!
          if (isAuthenticWatSafeResponse(netRes)) {
            try {
              const cache = await caches.open(SHELL_CACHE);
              await cache.put('/companion', netRes.clone());
            } catch (_) {}
            return netRes;
          }
        } catch (_) {}

        const cachedShell = await caches.match('/companion');
        if (cachedShell) {
          return cachedShell;
        }
        return new Response(
          '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>WATSafe</title></head>' +
            '<body style="margin:0;background:#141619;color:#F5F2EB;font-family:-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px;text-align:center;">' +
            '<div><h1 style="font-size:20px;margin-bottom:8px;">WATSafe — Service temporarily unavailable</h1>' +
            '<p style="color:#C8C2B6;font-size:14px;margin-bottom:16px;">Check your connection and tap Retry. Your pairing stays saved on this phone.</p>' +
            '<button onclick="location.reload()" style="background:#E58E26;color:#141619;border:none;border-radius:10px;padding:12px 20px;font-weight:700;font-size:15px;">Retry</button></div></body></html>',
          {
            status: 200,
            headers: { 'Content-Type': 'text/html; charset=utf-8' }
          }
        );
      })()
    );
    return;
  }

  if (
    url.pathname === '/manifest.webmanifest' ||
    url.pathname === '/manifest.json' ||
    url.pathname === '/favicon.png' ||
    url.pathname === '/apple-touch-icon.png' ||
    url.pathname.indexOf('/icons/') === 0
  ) {
    event.respondWith(
      (async () => {
        const lookupPath = url.pathname === '/manifest.json'
          ? '/manifest.webmanifest'
          : (url.pathname === '/apple-touch-icon.png' ? '/icons/apple-touch-icon.png' : url.pathname);
        const cached = await caches.match(lookupPath);
        const networkPromise = fetch(req)
          .then(async (res) => {
            if (isAuthenticWatSafeResponse(res)) {
              const cache = await caches.open(SHELL_CACHE);
              await cache.put(lookupPath, res.clone());
              return res;
            }
            return cached || res;
          })
          .catch(() => cached);
        return cached || networkPromise;
      })()
    );
    return;
  }

  if (url.pathname.indexOf('/v1/') === 0) {
    event.respondWith(
      fetch(req).catch(
        () =>
          new Response(
            JSON.stringify({
              error: 'NETWORK_UNAVAILABLE',
              offline: true,
              message: 'Service temporarily unavailable.'
            }),
            {
              status: 503,
              headers: {
                'Content-Type': 'application/json',
                'X-WATSafe-SW-Offline': '1'
              }
            }
          )
      )
    );
  }
});

self.addEventListener('pushsubscriptionchange', (event) => {
  event.waitUntil(
    (async () => {
      const saved = await readIdbStateSw();
      if (!saved || !saved.companionToken) return;
      let sub = event.newSubscription || null;
      if (!sub && self.registration && self.registration.pushManager && saved.vapidPublicKey) {
        try {
          sub = await self.registration.pushManager.subscribe({
            userVisibleOnly: true,
            applicationServerKey: urlBase64ToUint8ArraySw(saved.vapidPublicKey)
          });
        } catch (_) {}
      }
      if (!sub) return;
      const p256dh = arrayBufferToBase64UrlSw(sub.getKey('p256dh'));
      const auth = arrayBufferToBase64UrlSw(sub.getKey('auth'));
      if (!p256dh || !auth) return;
      try {
        const res = await fetch('/v1/companion/push-subscription', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + saved.companionToken
          },
          body: JSON.stringify({
            endpoint: sub.endpoint,
            p256dh: p256dh,
            auth: auth,
            httpsReady: true,
            homeScreenInstalled: true,
            notificationPermission: 'granted'
          })
        });
        if (isAuthenticWatSafeResponse(res)) {
          saved.pushEndpoint = sub.endpoint;
          saved.backendRegisteredEndpoint = sub.endpoint;
          saved.backendPushRegistered = true;
          await writeIdbStateSw(saved);
          const windowClients = await self.clients.matchAll({
            type: 'window',
            includeUncontrolled: true
          });
          for (const client of windowClients) {
            client.postMessage({
              type: 'PUSH_SUBSCRIPTION_RENEWED',
              endpoint: sub.endpoint
            });
          }
        }
      } catch (_) {}
    })()
  );
});

self.addEventListener('push', (event) => {
  let payload = {
    title: 'WATSafe Alert',
    body: 'Alarm triggered — tap to view event.',
    incidentId: '',
    pairingSessionId: '',
    isTest: false
  };
  try {
    if (event.data) {
      const parsed = event.data.json();
      payload.title = parsed.title || payload.title;
      payload.body = parsed.body || payload.body;
      const dataObj = parsed.data || {};
      payload.incidentId = dataObj.incidentId || parsed.incidentId || '';
      payload.pairingSessionId = dataObj.pairingSessionId || parsed.pairingSessionId || '';
      payload.isTest = Boolean(dataObj.isTest || parsed.isTest);
    }
  } catch (_) {}

  const tag = payload.incidentId
    ? ('watsafe-inc-' + payload.incidentId)
    : 'watsafe-alert';

  event.waitUntil(
    Promise.all([
      self.registration.showNotification(payload.title, {
        body: payload.body,
        tag: tag,
        renotify: false,
        icon: '/icons/icon-192.png',
        badge: '/icons/icon-192.png',
        data: {
          incidentId: payload.incidentId,
          pairingSessionId: payload.pairingSessionId,
          isTest: payload.isTest
        }
      }),
      self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windowClients) => {
        for (const client of windowClients) {
          client.postMessage({
            type: 'PUSH_RECEIVED',
            incidentId: payload.incidentId
          });
        }
      })
    ])
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const data = event.notification.data || {};
  const incidentId = data.incidentId || '';
  const targetUrl = incidentId
    ? '/companion?event=' + encodeURIComponent(incidentId)
    : '/companion';

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windowClients) => {
      for (const client of windowClients) {
        if ('focus' in client) {
          client.postMessage({
            type: 'OPEN_INCIDENT',
            incidentId: incidentId
          });
          return client.focus();
        }
      }
      if (self.clients.openWindow) {
        return self.clients.openWindow(targetUrl);
      }
    })
  );
});
''';

  static const String companionWebHtml = r'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="theme-color" content="#141619">
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
  <meta name="apple-mobile-web-app-title" content="WATSafe">
  <link rel="icon" type="image/png" href="/favicon.png">
  <link rel="apple-touch-icon" sizes="180x180" href="/icons/apple-touch-icon.png">
  <link rel="manifest" href="/manifest.webmanifest">
  <title>WATSafe Phone Companion</title>
  <style>
    :root {
      --bg: #141619;
      --surface: #1D2025;
      --elevated: #262A31;
      --border: #363C46;
      --text: #F5F2EB;
      --muted: #C8C2B6;
      --subtle: #948E83;
      --amber: #E58E26;
      --emerald: #2E9B68;
      --crimson: #D6453A;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
    }
    header {
      padding: calc(14px + env(safe-area-inset-top)) 20px 14px;
      border-bottom: 1px solid var(--border);
      display: flex;
      align-items: center;
      justify-content: space-between;
      background: var(--bg);
    }
    .brand { font-weight: 800; font-size: 18px; letter-spacing: 0.3px; display: flex; align-items: center; gap: 10px; }
    .shield-dot { width: 12px; height: 12px; border-radius: 50%; background: var(--amber); display: inline-block; }
    main { flex: 1; max-width: 540px; width: 100%; margin: 0 auto; padding: 20px; padding-bottom: 96px; }
    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 20px;
      margin-bottom: 16px;
    }
    h1 { font-size: 22px; margin: 0 0 8px 0; line-height: 1.3; }
    h2 { font-size: 17px; margin: 0 0 8px 0; }
    p { margin: 0 0 14px 0; color: var(--muted); line-height: 1.45; font-size: 14.5px; }
    label { display: block; font-size: 13px; color: var(--muted); margin-bottom: 6px; font-weight: 600; }
    input {
      width: 100%;
      padding: 13px 14px;
      border-radius: 10px;
      border: 1px solid var(--border);
      background: var(--elevated);
      color: var(--text);
      font-size: 16px;
      margin-bottom: 14px;
    }
    .btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 100%;
      padding: 14px 18px;
      border-radius: 12px;
      border: none;
      font-size: 15.5px;
      font-weight: 700;
      cursor: pointer;
      text-decoration: none;
      text-align: center;
      transition: opacity 0.15s;
    }
    .btn:disabled { opacity: 0.55; cursor: default; }
    .btn-primary { background: var(--amber); color: #141619; }
    .btn-secondary { background: var(--elevated); color: var(--text); border: 1px solid var(--border); margin-top: 10px; }
    .btn-danger { background: rgba(214,69,58,0.16); color: #ffb4ae; border: 1px solid var(--crimson); margin-top: 10px; }
    .pill {
      display: inline-block;
      padding: 4px 10px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
    }
    .pill-ok { background: rgba(46,155,104,0.18); color: #6ee7b7; border: 1px solid var(--emerald); }
    .pill-warn { background: rgba(229,142,38,0.18); color: #fcd34d; border: 1px solid var(--amber); }
    .pill-alert { background: rgba(214,69,58,0.2); color: #fca5a5; border: 1px solid var(--crimson); }
    .error-box {
      background: rgba(214,69,58,0.16);
      border: 1px solid var(--crimson);
      border-radius: 10px;
      padding: 12px 14px;
      color: var(--text);
      margin-bottom: 14px;
      font-size: 14px;
      line-height: 1.45;
    }
    .info-box {
      background: rgba(46,155,104,0.15);
      border: 1px solid var(--emerald);
      border-radius: 10px;
      padding: 12px 14px;
      color: var(--text);
      margin-bottom: 14px;
      font-size: 14px;
      line-height: 1.45;
    }
    .guide-box {
      background: var(--elevated);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 15px;
      margin: 14px 0;
    }
    .guide-box ol {
      margin: 8px 0 0 18px;
      padding: 0;
      color: var(--text);
      font-size: 14px;
      line-height: 1.55;
    }
    .guide-box li { margin-bottom: 6px; }
    .transfer-code {
      font-size: 24px;
      font-weight: 800;
      letter-spacing: 3px;
      color: var(--amber);
      text-align: center;
      padding: 10px;
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 10px;
      margin: 10px 0;
      user-select: all;
    }
    .checklist {
      border-top: 1px solid var(--border);
      margin-top: 16px;
      padding-top: 12px;
    }
    .check-row {
      display: flex;
      align-items: flex-start;
      gap: 10px;
      padding: 7px 0;
      font-size: 13.5px;
    }
    .check-icon {
      width: 20px;
      height: 20px;
      border-radius: 50%;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      font-size: 11px;
      font-weight: 800;
      flex-shrink: 0;
      margin-top: 1px;
    }
    .check-ok { background: rgba(46,155,104,0.22); color: #6ee7b7; border: 1px solid var(--emerald); }
    .check-next { background: rgba(229,142,38,0.22); color: #fcd34d; border: 1px solid var(--amber); }
    .check-pending { background: var(--elevated); color: var(--subtle); border: 1px solid var(--border); }
    .check-blocked { background: rgba(214,69,58,0.22); color: #fca5a5; border: 1px solid var(--crimson); }
    .event-item {
      background: var(--elevated);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 14px;
      margin-bottom: 10px;
      cursor: pointer;
    }
    .event-item.selected { border-color: var(--amber); border-width: 2px; }
    .nav-bar {
      position: fixed;
      bottom: 0; left: 0; right: 0;
      background: var(--surface);
      border-top: 1px solid var(--border);
      display: flex;
      justify-content: space-around;
      padding: 10px 8px calc(10px + env(safe-area-inset-bottom));
    }
    .nav-btn {
      background: none; border: none; color: var(--muted);
      font-size: 13px; font-weight: 700; padding: 8px 18px; border-radius: 999px; cursor: pointer;
    }
    .nav-btn.active { background: rgba(229,142,38,0.2); color: var(--amber); }
    .hidden { display: none !important; }
  </style>
</head>
<body>
  <header>
    <div class="brand"><span class="shield-dot" id="statusDot"></span> WATSafe</div>
    <span class="pill pill-warn" id="headerBadge">Connecting…</span>
  </header>
  <main>
    <div id="errorBox" class="error-box hidden"></div>
    <div id="infoBox" class="info-box hidden"></div>
    <div id="migrationBanner" class="guide-box hidden" style="border-color:var(--amber);"></div>
    <div id="connectionStatusBanner" class="guide-box hidden" style="border-color:var(--amber);">
      <div id="connectionStatusTitle" style="font-weight:700;color:var(--text);margin-bottom:4px;"></div>
      <div id="connectionStatusDetail" style="font-size:13.5px;color:var(--muted);line-height:1.45;"></div>
      <button id="retryConnectionBtn" class="btn btn-secondary" style="margin-top:10px;padding:10px 14px;font-size:14px;">Retry</button>
    </div>

    <!-- Step 1: Enter pairing code or Home Screen setup code -->
    <section id="stepCodeEntry" class="card hidden">
      <h1 id="codeEntryHeading">Pair your phone</h1>
      <p id="codeEntrySubtext">Scan the QR code on your laptop, or enter the 6-character setup code below.</p>
      <div id="httpPrePairNotice" class="guide-box hidden"></div>
      <label for="manualCodeInput">6-character code</label>
      <input id="manualCodeInput" type="text" placeholder="e.g. K7M-4P9" autocomplete="off" autocapitalize="characters">
      <button id="lookupCodeBtn" class="btn btn-primary">Continue</button>
    </section>

    <!-- Step 2: Connect to <Host>? confirmation -->
    <section id="stepConfirmPair" class="card hidden">
      <h1 id="confirmHeading">Connect to laptop?</h1>
      <p id="confirmSubtext">This phone will receive an alert and the protected device’s location if an alarm triggers.</p>
      <div id="confirmPlatformHint" class="guide-box hidden"></div>
      <label for="phoneNameInput">This phone’s name</label>
      <input id="phoneNameInput" type="text" maxlength="40">
      <button id="connectOneTapBtn" class="btn btn-primary">Connect</button>
      <button id="useDifferentCodeBtn" class="btn btn-secondary">Enter a different code</button>
    </section>

    <!-- Connected Home Tab (Guided Setup + Status + Test Alert) -->
    <section id="tabHome" class="hidden">
      <div class="card">
        <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;">
          <span class="pill pill-ok" id="homeConnBadge">Connecting…</span>
          <span class="pill pill-warn" id="homeNotifBadge">Setup needed</span>
        </div>
        <h1 id="homeHostTitle" style="margin-top:12px;">My Laptop</h1>
        <p id="homeHostPresenceText" style="font-size:13px;color:var(--subtle);margin-bottom:8px;"></p>
        <p id="homeNotifStatusText">Checking notification readiness…</p>

        <!-- Dynamic Next-Step Action Panel -->
        <div id="nextStepBox" class="guide-box hidden"></div>

        <!-- Primary Action Buttons (strictly shown only when valid for current step!) -->
        <button id="copyHandoffBtn" class="btn btn-primary hidden">Copy Home Screen setup code</button>
        <button id="enableNotifBtn" class="btn btn-primary hidden">Enable notifications</button>
        <button id="sendTestAlertBtn" class="btn btn-primary hidden">Send test alert</button>
        <button id="sendDelayedTestAlertBtn" class="btn btn-secondary hidden">Send test alert in 5s (lock phone test)</button>
        <a id="openHttpsLinkBtn" class="btn btn-primary hidden" href="#">Open secure HTTPS link</a>
        <button id="recheckSetupBtn" class="btn btn-secondary hidden">Re-check notification setup</button>

        <!-- 5-State Readiness Checklist -->
        <div class="checklist" id="readinessChecklist"></div>
      </div>
    </section>

    <!-- Connected Activity Tab -->
    <section id="tabActivity" class="hidden">
      <h1 style="margin-bottom:14px;">Activity</h1>
      <div id="eventDetailCard" class="card hidden"></div>
      <div id="eventsList"></div>
    </section>

    <!-- Connected Settings Tab -->
    <section id="tabSettings" class="hidden">
      <div class="card">
        <h2>Notifications &amp; connection</h2>
        <p id="settingsDeliverySummary"></p>
        <p id="settingsAddressSummary" style="font-size:13px;color:var(--subtle);"></p>
        <button id="settingsRecheckBtn" class="btn btn-secondary">Refresh notification status</button>
        <button id="disconnectPhoneBtn" class="btn btn-danger">Disconnect phone</button>
      </div>
    </section>
  </main>

  <nav id="bottomNav" class="nav-bar hidden">
    <button class="nav-btn active" data-tab="Home">Home</button>
    <button class="nav-btn" data-tab="Activity">Activity</button>
    <button class="nav-btn" data-tab="Settings">Settings</button>
  </nav>

  <script>
    const STORAGE_KEY = 'watsafe.web_companion.v3';
    const LEGACY_STORAGE_KEY = 'watsafe.web_companion.v2';
    const IDB_NAME = 'watsafe_companion_v2';
    const IDB_STORE = 'kv';
    const IDB_STATE_KEY = 'state';
    const TOKEN_REFRESH_INTERVAL_MS = 12 * 60 * 60 * 1000;
    const urlParams = new URLSearchParams(window.location.search);
    const initialCode = (urlParams.get('code') || '').trim();
    const initialSource = (urlParams.get('source') || '').trim();
    let pendingEventId = (urlParams.get('event') || '').trim();

    function isIosDevice() {
      const ua = navigator.userAgent || '';
      return /iPhone|iPad|iPod/i.test(ua) ||
        (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    }

    function isAndroidDevice() {
      return /Android/i.test(navigator.userAgent || '');
    }

    function isStandaloneWebApp() {
      return Boolean(
        window.navigator.standalone === true ||
        (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches)
      );
    }

    function isHttpsReady() {
      const host = window.location.hostname || '';
      const isLoopback = host === 'localhost' || host === '127.0.0.1' || host === '[::1]';
      return Boolean(window.isSecureContext) && (window.location.protocol === 'https:' || isLoopback);
    }

    function isEphemeralTunnelHost(rawHost) {
      const h = String(rawHost || window.location.hostname || '').toLowerCase();
      return h.endsWith('.trycloudflare.com') ||
        h.endsWith('.lhr.life') ||
        h.endsWith('.localhost.run') ||
        h.endsWith('.ngrok-free.app') ||
        h.endsWith('.ngrok-free.dev') ||
        h.endsWith('.ngrok.io');
    }

    function isAuthenticWatSafeHeader(res) {
      return Boolean(res && res.headers && res.headers.get('x-watsafe-companion') === '1');
    }

    async function isAuthenticUnauthorizedSession(res) {
      if (!res || res.status !== 401 || !isAuthenticWatSafeHeader(res)) {
        return false;
      }
      try {
        const cloned = res.clone();
        const body = await cloned.json();
        return Boolean(body && body.error === 'UNAUTHORIZED_COMPANION_SESSION');
      } catch (_) {
        return false;
      }
    }

    function generateInstallationDeviceId() {
      const arr = new Uint8Array(10);
      if (window.crypto && window.crypto.getRandomValues) {
        window.crypto.getRandomValues(arr);
      } else {
        for (let i = 0; i < arr.length; i++) arr[i] = Math.floor(Math.random() * 256);
      }
      let hex = '';
      for (let i = 0; i < arr.length; i++) hex += arr[i].toString(16).padStart(2, '0');
      return 'phone_' + hex;
    }

    function detectPhoneName() {
      if (isIosDevice()) {
        return /iPad/i.test(navigator.userAgent || '') ? 'iPad' : 'iPhone';
      }
      if (isAndroidDevice()) return 'Android Phone';
      return 'My Phone';
    }

    function detectPlatformLabel() {
      if (isIosDevice()) {
        return isStandaloneWebApp() ? 'iOS Home Screen Web App' : 'iOS Safari';
      }
      if (isAndroidDevice()) {
        return isStandaloneWebApp() ? 'Android Home Screen Web App' : 'Android Chrome';
      }
      return 'Mobile Web';
    }

    function urlBase64ToUint8Array(base64String) {
      const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
      const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
      const rawData = window.atob(base64);
      const outputArray = new Uint8Array(rawData.length);
      for (let i = 0; i < rawData.length; ++i) {
        outputArray[i] = rawData.charCodeAt(i);
      }
      return outputArray;
    }

    function arrayBufferToBase64Url(buffer) {
      if (!buffer) return '';
      const bytes = new Uint8Array(buffer);
      let binary = '';
      for (let i = 0; i < bytes.byteLength; i++) {
        binary += String.fromCharCode(bytes[i]);
      }
      return window.btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    }

    let state = {
      companionToken: null,
      pairingSessionId: null,
      deviceId: null,
      installationDeviceId: null,
      hostDisplayName: 'My Laptop',
      phoneDisplayName: detectPhoneName(),
      vapidPublicKey: null,
      httpsPublicOrigin: null,
      permanentHttpsOrigin: null,
      pushEndpoint: null,
      backendRegisteredEndpoint: null,
      backendPushRegistered: false,
      handoffCode: null,
      handoffExpiresAtUtc: null,
      tokenRefreshedAtIso: null,
      lastConnectedAtIso: null,
      hostOnline: true,
      hostLastSeenAtUtc: null,
      hostDisconnectedAtUtc: null,
      hostProtectionState: 'off',
      lastSeq: 0,
      seenIds: {},
      events: []
    };

    try {
      const raw = localStorage.getItem(STORAGE_KEY) || localStorage.getItem(LEGACY_STORAGE_KEY);
      if (raw) {
        const saved = JSON.parse(raw);
        state = Object.assign(state, saved);
      }
    } catch (_) {}

    function loadStateFromIdb() {
      return new Promise((resolve) => {
        if (typeof indexedDB === 'undefined') {
          resolve(null);
          return;
        }
        try {
          const req = indexedDB.open(IDB_NAME, 1);
          req.onupgradeneeded = () => {
            const db = req.result;
            if (!db.objectStoreNames.contains(IDB_STORE)) {
              db.createObjectStore(IDB_STORE);
            }
          };
          req.onsuccess = () => {
            try {
              const db = req.result;
              const tx = db.transaction(IDB_STORE, 'readonly');
              const getReq = tx.objectStore(IDB_STORE).get(IDB_STATE_KEY);
              getReq.onsuccess = () => {
                db.close();
                resolve(getReq.result || null);
              };
              getReq.onerror = () => {
                db.close();
                resolve(null);
              };
            } catch (_) {
              resolve(null);
            }
          };
          req.onerror = () => resolve(null);
        } catch (_) {
          resolve(null);
        }
      });
    }

    function writeStateToIdb(snapshot) {
      if (typeof indexedDB === 'undefined') return;
      try {
        const req = indexedDB.open(IDB_NAME, 1);
        req.onupgradeneeded = () => {
          const db = req.result;
          if (!db.objectStoreNames.contains(IDB_STORE)) {
            db.createObjectStore(IDB_STORE);
          }
        };
        req.onsuccess = () => {
          try {
            const db = req.result;
            const tx = db.transaction(IDB_STORE, 'readwrite');
            tx.objectStore(IDB_STORE).put(snapshot, IDB_STATE_KEY);
            tx.oncomplete = () => db.close();
            tx.onerror = () => db.close();
          } catch (_) {}
        };
      } catch (_) {}
    }

    function clearIdbState() {
      if (typeof indexedDB === 'undefined') return;
      try {
        const req = indexedDB.open(IDB_NAME, 1);
        req.onsuccess = () => {
          try {
            const db = req.result;
            if (db.objectStoreNames.contains(IDB_STORE)) {
              const tx = db.transaction(IDB_STORE, 'readwrite');
              tx.objectStore(IDB_STORE).delete(IDB_STATE_KEY);
              tx.oncomplete = () => db.close();
            } else {
              db.close();
            }
          } catch (_) {}
        };
      } catch (_) {}
    }

    function saveState() {
      if (!state.installationDeviceId) {
        state.installationDeviceId = state.deviceId || generateInstallationDeviceId();
      }
      try { localStorage.setItem(STORAGE_KEY, JSON.stringify(state)); } catch (_) {}
      try { writeStateToIdb(JSON.parse(JSON.stringify(state))); } catch (_) {}
    }

    async function hydrateDurableState() {
      const idbSaved = await loadStateFromIdb();
      if (idbSaved && typeof idbSaved === 'object') {
        if (!state.companionToken && idbSaved.companionToken) {
          state = Object.assign(state, idbSaved);
        } else if (state.companionToken && idbSaved.companionToken) {
          const localTime = state.lastConnectedAtIso ? new Date(state.lastConnectedAtIso).getTime() : 0;
          const idbTime = idbSaved.lastConnectedAtIso ? new Date(idbSaved.lastConnectedAtIso).getTime() : 0;
          if ((idbSaved.lastSeq || 0) > (state.lastSeq || 0) || idbTime > localTime) {
            state = Object.assign(state, idbSaved);
          }
        } else if (!state.installationDeviceId && idbSaved.installationDeviceId) {
          state.installationDeviceId = idbSaved.installationDeviceId;
        }
      }
      if (!state.installationDeviceId) {
        state.installationDeviceId = state.deviceId || generateInstallationDeviceId();
      }
      saveState();
    }

    // Strip any one-time code or query params from URL immediately so codes/tokens never linger in browser history.
    if (initialCode || initialSource) {
      const cleanPath = pendingEventId
        ? ('/companion?event=' + encodeURIComponent(pendingEventId))
        : '/companion';
      try { window.history.replaceState({}, '', cleanPath); } catch (_) {}
    }

    const els = {
      errorBox: document.getElementById('errorBox'),
      infoBox: document.getElementById('infoBox'),
      migrationBanner: document.getElementById('migrationBanner'),
      connectionStatusBanner: document.getElementById('connectionStatusBanner'),
      connectionStatusTitle: document.getElementById('connectionStatusTitle'),
      connectionStatusDetail: document.getElementById('connectionStatusDetail'),
      retryConnectionBtn: document.getElementById('retryConnectionBtn'),
      headerBadge: document.getElementById('headerBadge'),
      statusDot: document.getElementById('statusDot'),
      stepCodeEntry: document.getElementById('stepCodeEntry'),
      codeEntryHeading: document.getElementById('codeEntryHeading'),
      codeEntrySubtext: document.getElementById('codeEntrySubtext'),
      httpPrePairNotice: document.getElementById('httpPrePairNotice'),
      stepConfirmPair: document.getElementById('stepConfirmPair'),
      confirmPlatformHint: document.getElementById('confirmPlatformHint'),
      tabHome: document.getElementById('tabHome'),
      tabActivity: document.getElementById('tabActivity'),
      tabSettings: document.getElementById('tabSettings'),
      bottomNav: document.getElementById('bottomNav'),
      manualCodeInput: document.getElementById('manualCodeInput'),
      phoneNameInput: document.getElementById('phoneNameInput'),
      confirmHeading: document.getElementById('confirmHeading'),
      homeHostTitle: document.getElementById('homeHostTitle'),
      homeHostPresenceText: document.getElementById('homeHostPresenceText'),
      homeConnBadge: document.getElementById('homeConnBadge'),
      homeNotifBadge: document.getElementById('homeNotifBadge'),
      homeNotifStatusText: document.getElementById('homeNotifStatusText'),
      nextStepBox: document.getElementById('nextStepBox'),
      copyHandoffBtn: document.getElementById('copyHandoffBtn'),
      enableNotifBtn: document.getElementById('enableNotifBtn'),
      sendTestAlertBtn: document.getElementById('sendTestAlertBtn'),
      sendDelayedTestAlertBtn: document.getElementById('sendDelayedTestAlertBtn'),
      openHttpsLinkBtn: document.getElementById('openHttpsLinkBtn'),
      recheckSetupBtn: document.getElementById('recheckSetupBtn'),
      readinessChecklist: document.getElementById('readinessChecklist'),
      eventsList: document.getElementById('eventsList'),
      eventDetailCard: document.getElementById('eventDetailCard'),
      settingsDeliverySummary: document.getElementById('settingsDeliverySummary'),
      settingsAddressSummary: document.getElementById('settingsAddressSummary')
    };
    els.phoneNameInput.value = state.phoneDisplayName || detectPhoneName();

    let activeLookupCode = '';
    let activeTab = 'Home';
    let selectedIncidentId = pendingEventId || null;
    let swRegistration = null;
    let activePushSubscription = null;
    let connState = 'connecting'; // 'connecting' | 'connected' | 'laptop_offline' | 'service_unavailable'
    let consecutiveFailures = 0;
    let pollTimerId = null;

    function showError(msg) {
      if (!msg) { els.errorBox.classList.add('hidden'); return; }
      els.errorBox.textContent = msg;
      els.errorBox.classList.remove('hidden');
    }

    function showInfo(msg) {
      if (!msg) { els.infoBox.classList.add('hidden'); return; }
      els.infoBox.textContent = msg;
      els.infoBox.classList.remove('hidden');
    }

    function hideAllSections() {
      [els.stepCodeEntry, els.stepConfirmPair, els.tabHome, els.tabActivity, els.tabSettings]
        .forEach(el => el.classList.add('hidden'));
    }

    function escapeHtml(raw) {
      return String(raw || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
    }

    function updateHostPresenceFromPayload(payload) {
      if (!payload || typeof payload !== 'object') return;
      if (typeof payload.hostOnline === 'boolean') {
        state.hostOnline = payload.hostOnline;
      }
      if (payload.hostLastSeenAtUtc) {
        state.hostLastSeenAtUtc = payload.hostLastSeenAtUtc;
      }
      if (payload.hostDisconnectedAtUtc) {
        state.hostDisconnectedAtUtc = payload.hostDisconnectedAtUtc;
      }
      if (payload.hostProtectionState) {
        state.hostProtectionState = payload.hostProtectionState;
      }
      if (payload.permanentHttpsOrigin) {
        state.permanentHttpsOrigin = payload.permanentHttpsOrigin;
      }
      state.lastConnectedAtIso = new Date().toISOString();
      connState = state.hostOnline === false ? 'laptop_offline' : 'connected';
    }

    function renderMigrationBanner() {
      if (!isEphemeralTunnelHost()) {
        els.migrationBanner.classList.add('hidden');
        return;
      }
      const perm = state.permanentHttpsOrigin && state.permanentHttpsOrigin.indexOf('https://') === 0
        ? state.permanentHttpsOrigin
        : null;
      let actionHtml =
        '<p style="margin:8px 0 0 0;font-size:13px;color:var(--muted);">' +
        '<strong>Why one final migration is required:</strong> iPhone/Android isolate Home Screen apps, Service Workers, saved credentials, and Web Push subscriptions strictly by domain. Temporary <code>' + escapeHtml(window.location.hostname) + '</code> tunnels change when restarted. Deploy WATSafe’s permanent HTTPS relay once, remove this old Home Screen icon, and pair once on your permanent HTTPS URL.' +
        '</p>';
      if (perm && perm !== window.location.origin) {
        actionHtml +=
          '<a class="btn btn-primary" style="margin-top:10px;padding:10px 14px;font-size:14px;" href="' +
          escapeHtml(perm + '/companion') +
          '">Open permanent WATSafe address (' + escapeHtml(perm) + ')</a>';
      }
      els.migrationBanner.innerHTML =
        '<strong>Temporary tunnel address (' + escapeHtml(window.location.hostname) + ')</strong>' +
        actionHtml;
      els.migrationBanner.classList.remove('hidden');
    }

    // Separate 5-state detection required by modern iOS Safari/PWA & Android Chrome
    function evaluateReadiness() {
      const httpsOk = isHttpsReady();
      const ios = isIosDevice();
      const standalone = isStandaloneWebApp();
      const homeScreenRequired = ios;
      const homeScreenOk = homeScreenRequired ? standalone : true;

      const hasPushApis = httpsOk &&
        ('Notification' in window) &&
        ('serviceWorker' in navigator) &&
        ('PushManager' in window);

      let permission = 'unavailable';
      if (hasPushApis) {
        permission = Notification.permission; // 'default' | 'granted' | 'denied'
      }

      const subscribedOk = Boolean(
        hasPushApis &&
        permission === 'granted' &&
        activePushSubscription &&
        state.pushEndpoint
      );

      const backendOk = Boolean(
        subscribedOk &&
        state.backendPushRegistered &&
        state.backendRegisteredEndpoint === state.pushEndpoint
      );

      return {
        httpsReady: httpsOk,
        isIos: ios,
        isStandalone: standalone,
        homeScreenRequired: homeScreenRequired,
        homeScreenInstalled: homeScreenOk,
        hasPushApis: hasPushApis,
        notificationPermission: permission,
        pushSubscribed: subscribedOk,
        backendPushRegistered: backendOk,
        notificationsEnabled: httpsOk && homeScreenOk && permission === 'granted' && subscribedOk && backendOk
      };
    }

    async function fetchServerRuntimeHealth() {
      try {
        const res = await fetch('/v1/health', { cache: 'no-store' });
        if (!isAuthenticWatSafeHeader(res) || !res.ok) return false;
        const data = await res.json();
        if (data.vapidPublicKey) state.vapidPublicKey = data.vapidPublicKey;
        if (data.publicHttpsOrigin) state.httpsPublicOrigin = data.publicHttpsOrigin;
        if (data.permanentHttpsOrigin) state.permanentHttpsOrigin = data.permanentHttpsOrigin;
        state.lastConnectedAtIso = new Date().toISOString();
        saveState();
        renderMigrationBanner();
        return true;
      } catch (_) {
        return false;
      }
    }

    async function ensureServiceWorkerAndInspectSubscription() {
      if (!isHttpsReady() || !('serviceWorker' in navigator)) {
        swRegistration = null;
        activePushSubscription = null;
        return;
      }
      try {
        if (!swRegistration) {
          swRegistration = await navigator.serviceWorker.register('/sw.js', {
            scope: '/',
            updateViaCache: 'none'
          });
        } else {
          swRegistration.update().catch(() => {});
        }
        const readyReg = await navigator.serviceWorker.ready;
        swRegistration = readyReg;
        if (readyReg && readyReg.pushManager) {
          activePushSubscription = await readyReg.pushManager.getSubscription();
          state.pushEndpoint = activePushSubscription ? activePushSubscription.endpoint : null;
          saveState();
        }
      } catch (_) {}
    }

    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.addEventListener('message', async (ev) => {
        if (!ev.data) return;
        if (ev.data.type === 'PUSH_RECEIVED' && ev.data.incidentId) {
          state.seenIds[ev.data.incidentId] = true;
          saveState();
          triggerImmediateReconnect();
        }
        if (ev.data.type === 'OPEN_INCIDENT' && ev.data.incidentId) {
          selectedIncidentId = ev.data.incidentId;
          switchTab('Activity');
          fetchSingleIncidentIfMissing(selectedIncidentId);
        }
        if (ev.data.type === 'PUSH_SUBSCRIPTION_RENEWED' && ev.data.endpoint) {
          state.pushEndpoint = ev.data.endpoint;
          state.backendRegisteredEndpoint = ev.data.endpoint;
          state.backendPushRegistered = true;
          saveState();
          await ensureServiceWorkerAndInspectSubscription();
          renderConnectedUi();
        }
        if (ev.data.type === 'SW_ACTIVATED') {
          if (state.companionToken) {
            syncCompanionReadinessToBackend();
          }
        }
      });
    }

    async function maybeRefreshCompanionToken() {
      if (!state.companionToken) return;
      const lastRef = state.tokenRefreshedAtIso ? new Date(state.tokenRefreshedAtIso).getTime() : 0;
      if (lastRef > 0 && (Date.now() - lastRef) < TOKEN_REFRESH_INTERVAL_MS) {
        return;
      }
      try {
        const res = await fetch('/v1/companion/token/refresh', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + state.companionToken
          },
          body: JSON.stringify({})
        });
        if (await isAuthenticUnauthorizedSession(res)) {
          await handleServerRevokedSession();
          return;
        }
        if (isAuthenticWatSafeHeader(res) && res.ok) {
          const body = await res.json();
          if (body.companionToken) {
            state.companionToken = body.companionToken;
            state.tokenRefreshedAtIso = body.tokenRefreshedAtUtc || new Date().toISOString();
            if (body.vapidPublicKey) state.vapidPublicKey = body.vapidPublicKey;
            updateHostPresenceFromPayload(body);
            saveState();
          }
        }
      } catch (_) {}
    }

    async function syncCompanionReadinessToBackend() {
      if (!state.companionToken) return;
      await ensureServiceWorkerAndInspectSubscription();
      let r = evaluateReadiness();

      // Automatic push subscription renewal when permission is already granted!
      if (r.httpsReady && r.homeScreenInstalled && r.notificationPermission === 'granted') {
        if (!activePushSubscription && swRegistration && swRegistration.pushManager) {
          if (!state.vapidPublicKey) {
            await fetchServerRuntimeHealth();
          }
          if (state.vapidPublicKey) {
            try {
              activePushSubscription = await swRegistration.pushManager.subscribe({
                userVisibleOnly: true,
                applicationServerKey: urlBase64ToUint8Array(state.vapidPublicKey)
              });
              state.pushEndpoint = activePushSubscription ? activePushSubscription.endpoint : null;
              saveState();
              r = evaluateReadiness();
            } catch (_) {}
          }
        }
        if (activePushSubscription) {
          const p256dh = arrayBufferToBase64Url(activePushSubscription.getKey('p256dh'));
          const auth = arrayBufferToBase64Url(activePushSubscription.getKey('auth'));
          if (p256dh && auth && (!state.backendPushRegistered || state.backendRegisteredEndpoint !== activePushSubscription.endpoint)) {
            try {
              await registerPushSubscriptionWithBackend(activePushSubscription, p256dh, auth);
              return;
            } catch (_) {}
          }
        }
      }

      const channel = r.notificationsEnabled
        ? 'web_push'
        : (!r.httpsReady ? 'needs_https' : (!r.homeScreenInstalled ? 'needs_home_screen' : (r.notificationPermission === 'denied' ? 'denied' : 'foreground_only')));

      try {
        const res = await fetch('/v1/companion/status', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + state.companionToken
          },
          body: JSON.stringify({
            platform: detectPlatformLabel(),
            httpsReady: r.httpsReady,
            homeScreenInstalled: r.homeScreenInstalled,
            notificationPermission: r.notificationPermission,
            pushSubscribed: r.pushSubscribed,
            notificationsEnabled: r.notificationsEnabled,
            notificationChannel: channel
          })
        });
        if (await isAuthenticUnauthorizedSession(res)) {
          await handleServerRevokedSession();
          return;
        }
        if (isAuthenticWatSafeHeader(res) && res.ok) {
          const updated = await res.json();
          state.backendPushRegistered = Boolean(updated.backendPushRegistered);
          if (updated.vapidPublicKey) state.vapidPublicKey = updated.vapidPublicKey;
          updateHostPresenceFromPayload(updated);
          consecutiveFailures = 0;
          saveState();
        }
      } catch (_) {}
      renderConnectedUi();
    }

    async function registerPushSubscriptionWithBackend(sub, p256dh, auth) {
      const r = evaluateReadiness();
      const res = await fetch('/v1/companion/push-subscription', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + state.companionToken
        },
        body: JSON.stringify({
          endpoint: sub.endpoint,
          p256dh: p256dh,
          auth: auth,
          platform: detectPlatformLabel(),
          httpsReady: r.httpsReady,
          homeScreenInstalled: r.homeScreenInstalled,
          notificationPermission: 'granted'
        })
      });
      if (await isAuthenticUnauthorizedSession(res)) {
        await handleServerRevokedSession();
        throw new Error('This phone was disconnected. Please pair again.');
      }
      if (!isAuthenticWatSafeHeader(res)) {
        throw new Error('WATSafe service is temporarily unavailable. Retry in a moment.');
      }
      const body = await res.json();
      if (!res.ok) {
        throw new Error(body.message || 'Server rejected push subscription registration.');
      }
      state.pushEndpoint = sub.endpoint;
      state.backendRegisteredEndpoint = sub.endpoint;
      state.backendPushRegistered = Boolean(body.backendPushRegistered);
      state.lastConnectedAtIso = new Date().toISOString();
      saveState();
      renderConnectedUi();
    }

    async function ensureIosHandoffCode() {
      if (!state.companionToken) return;
      const r = evaluateReadiness();
      if (!r.httpsReady || !r.isIos || r.isStandalone) return;
      if (state.handoffCode && state.handoffExpiresAtUtc) {
        const exp = new Date(state.handoffExpiresAtUtc).getTime();
        if (!isNaN(exp) && exp - Date.now() > 60000) {
          renderConnectedUi();
          return;
        }
      }
      try {
        const res = await fetch('/v1/companion/handoff-code', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + state.companionToken
          },
          body: JSON.stringify({})
        });
        if (isAuthenticWatSafeHeader(res) && res.ok) {
          const body = await res.json();
          state.handoffCode = body.handoffCode || null;
          state.handoffExpiresAtUtc = body.expiresAtUtc || null;
          saveState();
          renderConnectedUi();
        }
      } catch (_) {}
    }

    async function handleServerRevokedSession() {
      if (pollTimerId) {
        clearTimeout(pollTimerId);
        pollTimerId = null;
      }
      localStorage.removeItem(STORAGE_KEY);
      localStorage.removeItem(LEGACY_STORAGE_KEY);
      clearIdbState();
      state.companionToken = null;
      state.backendPushRegistered = false;
      state.pushEndpoint = null;
      state.backendRegisteredEndpoint = null;
      els.bottomNav.classList.add('hidden');
      els.connectionStatusBanner.classList.add('hidden');
      els.headerBadge.textContent = 'Phone setup';
      els.headerBadge.className = 'pill pill-warn';
      showError(
        'This phone was explicitly disconnected from ' +
          (state.hostDisplayName || 'your laptop') +
          '. Scan a new QR code or enter a setup code to pair again.'
      );
      renderPrePairUi();
      hideAllSections();
      els.stepCodeEntry.classList.remove('hidden');
    }

    function renderPrePairUi() {
      els.headerBadge.textContent = 'Phone setup';
      els.headerBadge.className = 'pill pill-warn';
      els.connectionStatusBanner.classList.add('hidden');
      renderMigrationBanner();
      if (isStandaloneWebApp()) {
        els.codeEntryHeading.textContent = 'Finish Home Screen setup';
        els.codeEntrySubtext.textContent =
          'Paste the 6-character setup code copied from Safari, or enter a fresh pairing code from your laptop.';
      } else {
        els.codeEntryHeading.textContent = 'Pair your phone';
        els.codeEntrySubtext.textContent =
          'Enter the 6-character code shown on your laptop screen.';
      }

      if (!isHttpsReady()) {
        els.httpPrePairNotice.innerHTML =
          '<strong>Plain HTTP address detected (' + escapeHtml(window.location.host) + ')</strong>' +
          '<p style="margin:6px 0 0 0;font-size:13.5px;">iPhone and Android require an <code>https://</code> connection for lock-screen push notifications. Start WATSafe with your permanent HTTPS relay (or <code>./scripts/run_watsafe.sh</code>) and scan the HTTPS QR code.</p>';
        els.httpPrePairNotice.classList.remove('hidden');
      } else {
        els.httpPrePairNotice.classList.add('hidden');
      }
    }

    async function submitCodeOrHandoff(rawCode) {
      const code = (rawCode || '').trim();
      if (!code) {
        showError('Enter the 6-character code from Safari or your laptop.');
        return;
      }
      showError('');
      showInfo('');

      // Inside an installed Home Screen app (or any unpaired client), check if this code is a Safari->Home Screen handoff code first!
      try {
        const claimRes = await fetch('/v1/companion/claim-handoff', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            handoffCode: code,
            platform: detectPlatformLabel(),
            httpsReady: isHttpsReady(),
            homeScreenInstalled: isStandaloneWebApp() || !isIosDevice()
          })
        });
        if (isAuthenticWatSafeHeader(claimRes) && claimRes.ok) {
          const claimBody = await claimRes.json();
          state.companionToken = claimBody.companionToken;
          state.pairingSessionId = claimBody.pairingSessionId;
          state.deviceId = claimBody.deviceId;
          state.installationDeviceId = claimBody.deviceId || state.installationDeviceId;
          state.hostDisplayName = claimBody.hostDisplayName || state.hostDisplayName;
          state.vapidPublicKey = claimBody.vapidPublicKey || state.vapidPublicKey;
          state.backendPushRegistered = Boolean(claimBody.backendPushRegistered);
          state.tokenRefreshedAtIso = new Date().toISOString();
          state.handoffCode = null;
          updateHostPresenceFromPayload(claimBody);
          saveState();
          showInfo('Paired session restored in Home Screen app. Next, tap Enable notifications below.');
          await syncCompanionReadinessToBackend();
          enterConnectedShell();
          return;
        }
      } catch (_) {}

      await lookupCode(code);
    }

    async function lookupCode(code) {
      showError('');
      try {
        const res = await fetch('/v1/pairing/lookup?code=' + encodeURIComponent(code));
        if (!isAuthenticWatSafeHeader(res)) {
          showError('Service temporarily unavailable. Check your connection and tap Continue to retry.');
          renderPrePairUi();
          hideAllSections();
          els.stepCodeEntry.classList.remove('hidden');
          els.manualCodeInput.value = code;
          return;
        }
        const body = await res.json();
        if (!res.ok) {
          showError(body.message || 'Could not verify code.');
          renderPrePairUi();
          hideAllSections();
          els.stepCodeEntry.classList.remove('hidden');
          els.manualCodeInput.value = code;
          return;
        }
        activeLookupCode = body.pairingCode || code;
        state.hostDisplayName = body.hostDisplayName || 'My Laptop';
        if (body.vapidPublicKey) state.vapidPublicKey = body.vapidPublicKey;
        els.confirmHeading.textContent = 'Connect to ' + state.hostDisplayName + '?';

        if (!isHttpsReady()) {
          els.confirmPlatformHint.innerHTML =
            '<strong>Note:</strong> This page is using plain HTTP (<code>' + escapeHtml(window.location.origin) + '</code>). Pairing will connect for live foreground viewing, but lock-screen notifications require opening WATSafe via <code>https://</code>.';
          els.confirmPlatformHint.classList.remove('hidden');
        } else if (isIosDevice() && !isStandaloneWebApp()) {
          els.confirmPlatformHint.innerHTML =
            '<strong>One-time iPhone setup:</strong> Tap <strong>Connect</strong> below, then add WATSafe to your Home Screen once to enable permanent lock-screen notifications.';
          els.confirmPlatformHint.classList.remove('hidden');
        } else {
          els.confirmPlatformHint.classList.add('hidden');
        }

        hideAllSections();
        els.stepConfirmPair.classList.remove('hidden');
      } catch (_) {
        showError('Service temporarily unavailable. Check your internet or Wi-Fi connection and try again.');
        renderPrePairUi();
        hideAllSections();
        els.stepCodeEntry.classList.remove('hidden');
      }
    }

    document.getElementById('lookupCodeBtn').addEventListener('click', () => {
      submitCodeOrHandoff(els.manualCodeInput.value);
    });

    els.manualCodeInput.addEventListener('keydown', (ev) => {
      if (ev.key === 'Enter') submitCodeOrHandoff(els.manualCodeInput.value);
    });

    document.getElementById('useDifferentCodeBtn').addEventListener('click', () => {
      showError('');
      renderPrePairUi();
      hideAllSections();
      els.stepCodeEntry.classList.remove('hidden');
    });

    document.getElementById('connectOneTapBtn').addEventListener('click', async (ev) => {
      ev.target.disabled = true;
      showError('');
      showInfo('');
      try {
        const phoneName = els.phoneNameInput.value.trim() || detectPhoneName();
        const r = evaluateReadiness();
        const preferredDeviceId = state.installationDeviceId || state.deviceId || generateInstallationDeviceId();
        state.installationDeviceId = preferredDeviceId;
        const res = await fetch('/v1/pairing/complete', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            pairingCode: activeLookupCode,
            deviceId: preferredDeviceId,
            displayName: phoneName,
            platform: detectPlatformLabel(),
            httpsReady: r.httpsReady,
            homeScreenInstalled: r.homeScreenInstalled,
            notificationPermission: r.notificationPermission,
            notificationsEnabled: false,
            notificationChannel: r.httpsReady ? (r.homeScreenInstalled ? 'pending_permission' : 'needs_home_screen') : 'needs_https'
          })
        });
        if (!isAuthenticWatSafeHeader(res)) {
          showError('Service temporarily unavailable. Please retry in a moment.');
          return;
        }
        const body = await res.json();
        if (!res.ok) {
          showError(body.message || 'Could not complete pairing.');
          renderPrePairUi();
          hideAllSections();
          els.stepCodeEntry.classList.remove('hidden');
          return;
        }
        state.companionToken = body.companionToken;
        state.pairingSessionId = body.pairingSessionId;
        state.deviceId = body.deviceId || preferredDeviceId;
        state.installationDeviceId = state.deviceId;
        state.hostDisplayName = body.hostDisplayName || state.hostDisplayName;
        state.phoneDisplayName = phoneName;
        if (body.vapidPublicKey) state.vapidPublicKey = body.vapidPublicKey;
        state.tokenRefreshedAtIso = new Date().toISOString();
        state.backendPushRegistered = false;
        state.pushEndpoint = null;
        state.backendRegisteredEndpoint = null;
        state.lastSeq = 0;
        state.seenIds = {};
        state.events = [];
        updateHostPresenceFromPayload(body);
        saveState();

        await ensureServiceWorkerAndInspectSubscription();
        await ensureIosHandoffCode();
        await syncCompanionReadinessToBackend();
        enterConnectedShell();
      } catch (_) {
        showError('Service temporarily unavailable. Please check your network and try again.');
      } finally {
        ev.target.disabled = false;
      }
    });

    // Explicit user tap inside installed Home Screen app (iOS) or HTTPS Chrome (Android)
    async function handleExplicitEnableNotificationsTap(ev) {
      if (ev && ev.currentTarget) ev.currentTarget.disabled = true;
      showError('');
      showInfo('');
      try {
        const initial = evaluateReadiness();
        if (!initial.httpsReady) {
          showError('HTTPS is required before notifications can be enabled. Open WATSafe over https:// and try again.');
          renderConnectedUi();
          return;
        }
        if (!initial.homeScreenInstalled) {
          showError('On iPhone, add WATSafe to your Home Screen first, open the WATSafe Home Screen icon, and then tap Enable notifications.');
          renderConnectedUi();
          return;
        }
        if (!('Notification' in window) || !('serviceWorker' in navigator) || !('PushManager' in window)) {
          showError('Web Push APIs are unavailable in this browser mode. On iPhone, make sure iOS is 16.4 or newer and open WATSafe from your Home Screen icon.');
          renderConnectedUi();
          return;
        }

        // 1. Request OS notification permission directly from this explicit user tap
        let perm = Notification.permission;
        if (perm === 'default') {
          perm = await Notification.requestPermission();
        }
        if (perm !== 'granted') {
          await syncCompanionReadinessToBackend();
          return;
        }

        // 2. Ensure Service Worker & VAPID public key are ready
        if (!state.vapidPublicKey) {
          await fetchServerRuntimeHealth();
        }
        if (!state.vapidPublicKey) {
          showError('Server push key is unavailable right now. Tap Re-check notification setup.');
          return;
        }

        swRegistration = await navigator.serviceWorker.register('/sw.js', {
          scope: '/',
          updateViaCache: 'none'
        });
        const readyReg = await navigator.serviceWorker.ready;

        // 3. Create or reuse Web Push subscription
        let sub = await readyReg.pushManager.getSubscription();
        if (!sub) {
          sub = await readyReg.pushManager.subscribe({
            userVisibleOnly: true,
            applicationServerKey: urlBase64ToUint8Array(state.vapidPublicKey)
          });
        }
        activePushSubscription = sub;

        const p256dh = arrayBufferToBase64Url(sub.getKey('p256dh'));
        const auth = arrayBufferToBase64Url(sub.getKey('auth'));
        if (!p256dh || !auth) {
          throw new Error('Browser did not return Web Push encryption keys.');
        }

        // 4. Register subscription with backend for this paired device
        await registerPushSubscriptionWithBackend(sub, p256dh, auth);
        showInfo('Notifications enabled! Pairing and notifications are saved permanently — tap "Send test alert" to verify.');
      } catch (err) {
        showError((err && err.message) ? err.message : 'Could not finish notification setup. Please try again.');
        await syncCompanionReadinessToBackend();
      } finally {
        if (ev && ev.currentTarget) ev.currentTarget.disabled = false;
      }
    }

    els.enableNotifBtn.addEventListener('click', handleExplicitEnableNotificationsTap);

    els.copyHandoffBtn.addEventListener('click', async () => {
      if (!state.handoffCode) {
        await ensureIosHandoffCode();
      }
      if (!state.handoffCode) return;
      try {
        await navigator.clipboard.writeText(state.handoffCode);
        showInfo('Copied code ' + state.handoffCode + '! Now tap Safari’s Share button → Add to Home Screen, then open the WATSafe icon on your Home Screen.');
      } catch (_) {
        showInfo('Copy setup code ' + state.handoffCode + ', then tap Share → Add to Home Screen.');
      }
    });

    async function triggerCompanionTestAlert(delaySeconds) {
      if (!state.companionToken) return;
      showError('');
      els.sendTestAlertBtn.disabled = true;
      els.sendDelayedTestAlertBtn.disabled = true;
      try {
        if (delaySeconds > 0) {
          showInfo('Lock your phone screen now — sending real Web Push test alert in ' + delaySeconds + ' seconds…');
        }
        const res = await fetch('/v1/companion/test-alert', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + state.companionToken
          },
          body: JSON.stringify({ delaySeconds: delaySeconds })
        });
        if (await isAuthenticUnauthorizedSession(res)) {
          await handleServerRevokedSession();
          return;
        }
        if (!isAuthenticWatSafeHeader(res)) {
          showError('Service temporarily unavailable. Your pairing is preserved — tap Retry above and try again.');
          return;
        }
        const body = await res.json();
        if (!res.ok) {
          showError(body.message || 'Could not send test alert.');
          return;
        }
        if (delaySeconds > 0) {
          showInfo('Test alert delivered! Tap the notification or check Activity to view the event and laptop location.');
        } else {
          showInfo(body.pushDispatchedCount > 0
            ? 'Test alert sent via Web Push! Check your notification banner or open Activity.'
            : 'Test alert recorded in Activity (complete notification setup to receive lock-screen banners).');
        }
        await pollAlerts();
      } catch (_) {
        showError('Service temporarily unavailable — could not send test alert right now.');
      } finally {
        els.sendTestAlertBtn.disabled = false;
        els.sendDelayedTestAlertBtn.disabled = false;
      }
    }

    els.sendTestAlertBtn.addEventListener('click', () => triggerCompanionTestAlert(0));
    els.sendDelayedTestAlertBtn.addEventListener('click', () => triggerCompanionTestAlert(5));
    els.recheckSetupBtn.addEventListener('click', () => {
      showError('');
      showInfo('');
      triggerImmediateReconnect();
    });
    document.getElementById('settingsRecheckBtn').addEventListener('click', () => {
      triggerImmediateReconnect();
      showInfo('Connection and notification status refreshed.');
    });
    els.retryConnectionBtn.addEventListener('click', () => {
      showError('');
      connState = 'connecting';
      renderConnectedUi();
      triggerImmediateReconnect();
    });

    document.getElementById('disconnectPhoneBtn').addEventListener('click', async () => {
      if (pollTimerId) {
        clearTimeout(pollTimerId);
        pollTimerId = null;
      }
      if (state.companionToken) {
        try {
          await fetch('/v1/companion/disconnect', {
            method: 'POST',
            headers: { 'Authorization': 'Bearer ' + state.companionToken }
          });
        } catch (_) {}
      }
      if (activePushSubscription) {
        try { await activePushSubscription.unsubscribe(); } catch (_) {}
        activePushSubscription = null;
      }
      localStorage.removeItem(STORAGE_KEY);
      localStorage.removeItem(LEGACY_STORAGE_KEY);
      clearIdbState();
      state.companionToken = null;
      state.backendPushRegistered = false;
      state.pushEndpoint = null;
      state.backendRegisteredEndpoint = null;
      els.bottomNav.classList.add('hidden');
      els.connectionStatusBanner.classList.add('hidden');
      els.headerBadge.textContent = 'Disconnected';
      els.headerBadge.className = 'pill pill-warn';
      renderPrePairUi();
      hideAllSections();
      els.stepCodeEntry.classList.remove('hidden');
    });

    document.querySelectorAll('.nav-btn').forEach(btn => {
      btn.addEventListener('click', () => switchTab(btn.dataset.tab));
    });

    function switchTab(tab) {
      activeTab = tab;
      document.querySelectorAll('.nav-btn').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
      hideAllSections();
      if (tab === 'Home') els.tabHome.classList.remove('hidden');
      if (tab === 'Activity') els.tabActivity.classList.remove('hidden');
      if (tab === 'Settings') els.tabSettings.classList.remove('hidden');
      renderConnectedUi();
    }

    function enterConnectedShell() {
      els.bottomNav.classList.remove('hidden');
      if (selectedIncidentId) {
        switchTab('Activity');
        fetchSingleIncidentIfMissing(selectedIncidentId);
      } else {
        switchTab(activeTab);
      }
      scheduleNextPoll(0);
    }

    function formatTime(iso) {
      if (!iso) return 'not yet recorded';
      const d = new Date(iso);
      return isNaN(d.getTime()) ? String(iso) : d.toLocaleString();
    }

    function formatProtectionLabel(raw) {
      const s = String(raw || 'off').toLowerCase();
      if (s === 'monitoring' || s === 'protected') return 'Protected';
      if (s === 'arming') return 'Arming';
      if (s === 'paused') return 'Monitoring paused';
      if (s === 'triggered') return 'Alarm triggered';
      return 'Protection off';
    }

    function hideAllHomeActions() {
      [
        els.nextStepBox,
        els.copyHandoffBtn,
        els.enableNotifBtn,
        els.sendTestAlertBtn,
        els.sendDelayedTestAlertBtn,
        els.openHttpsLinkBtn,
        els.recheckSetupBtn
      ].forEach(el => el.classList.add('hidden'));
    }

    function renderChecklistItem(status, title, detail) {
      const cls = status === 'ok'
        ? 'check-ok'
        : (status === 'next' ? 'check-next' : (status === 'blocked' ? 'check-blocked' : 'check-pending'));
      const symbol = status === 'ok' ? '✓' : (status === 'blocked' ? '!' : '•');
      return '<div class="check-row">' +
        '<span class="check-icon ' + cls + '">' + symbol + '</span>' +
        '<div><div style="font-weight:700;color:var(--text);">' + escapeHtml(title) + '</div>' +
        '<div style="color:var(--muted);font-size:12.5px;">' + escapeHtml(detail) + '</div></div>' +
        '</div>';
    }

    function renderConnectionStateUi(r) {
      renderMigrationBanner();
      const lastSeenHost = state.hostLastSeenAtUtc || state.hostDisconnectedAtUtc || state.lastConnectedAtIso;
      const lastRelayConn = state.lastConnectedAtIso;

      if (connState === 'connecting') {
        els.homeConnBadge.textContent = 'Connecting…';
        els.homeConnBadge.className = 'pill pill-warn';
        els.headerBadge.textContent = 'Connecting…';
        els.headerBadge.className = 'pill pill-warn';
        els.statusDot.style.background = '#E58E26';
        els.homeHostPresenceText.textContent = lastRelayConn
          ? ('Reconnecting to WATSafe · Last connected ' + formatTime(lastRelayConn))
          : 'Connecting to WATSafe…';
        els.connectionStatusBanner.classList.add('hidden');
      } else if (connState === 'service_unavailable') {
        els.homeConnBadge.textContent = 'Service temporarily unavailable';
        els.homeConnBadge.className = 'pill pill-warn';
        els.headerBadge.textContent = 'Service temporarily unavailable';
        els.headerBadge.className = 'pill pill-warn';
        els.statusDot.style.background = '#E58E26';
        els.homeHostPresenceText.textContent =
          'Last connected ' + formatTime(lastRelayConn) + ' · Pairing saved on this phone';
        els.connectionStatusTitle.textContent = 'Service temporarily unavailable';
        els.connectionStatusDetail.textContent =
          'Last connected: ' +
          formatTime(lastRelayConn) +
          '. Your pairing and notification setup remain saved — WATSafe is retrying automatically in the background.';
        els.connectionStatusBanner.classList.remove('hidden');
      } else if (connState === 'laptop_offline') {
        els.homeConnBadge.textContent = 'Laptop offline';
        els.homeConnBadge.className = 'pill pill-warn';
        els.headerBadge.textContent = 'Laptop offline';
        els.headerBadge.className = 'pill pill-warn';
        els.statusDot.style.background = '#E58E26';
        els.homeHostPresenceText.textContent =
          'Laptop offline · Last seen ' + formatTime(lastSeenHost);
        els.connectionStatusTitle.textContent = 'Laptop offline';
        els.connectionStatusDetail.textContent =
          (state.hostDisplayName || 'Your laptop') +
          ' is currently closed or offline (last seen ' +
          formatTime(lastSeenHost) +
          '). Your pairing and lock-screen notifications stay active — WATSafe reconnects automatically when your laptop opens.';
        els.connectionStatusBanner.classList.remove('hidden');
      } else {
        els.homeConnBadge.textContent = 'Connected';
        els.homeConnBadge.className = 'pill pill-ok';
        els.headerBadge.textContent = r.notificationsEnabled ? 'Notifications enabled' : 'Connected';
        els.headerBadge.className = r.notificationsEnabled ? 'pill pill-ok' : 'pill pill-warn';
        els.statusDot.style.background = r.notificationsEnabled ? '#2E9B68' : '#E58E26';
        els.homeHostPresenceText.textContent =
          'Laptop online (' +
          formatProtectionLabel(state.hostProtectionState) +
          ') · Last seen ' +
          formatTime(lastSeenHost || lastRelayConn);
        els.connectionStatusBanner.classList.add('hidden');
      }
    }

    function renderConnectedUi() {
      if (!state.companionToken) return;
      const r = evaluateReadiness();
      els.homeHostTitle.textContent = state.hostDisplayName || 'Protected Laptop';
      hideAllHomeActions();
      renderConnectionStateUi(r);

      if (r.notificationsEnabled) {
        els.homeNotifBadge.textContent = 'Notifications enabled';
        els.homeNotifBadge.className = 'pill pill-ok';
        els.homeNotifStatusText.textContent =
          'Lock-screen and background Web Push alerts are active for ' + (state.hostDisplayName || 'your laptop') + '.';
        els.sendTestAlertBtn.classList.remove('hidden');
        els.sendDelayedTestAlertBtn.classList.remove('hidden');
      } else {
        els.homeNotifBadge.textContent = 'Notifications not ready';
        els.homeNotifBadge.className = 'pill pill-warn';

        if (!r.httpsReady) {
          els.homeNotifStatusText.textContent =
            'Paired with ' + (state.hostDisplayName || 'your laptop') + ', but lock-screen notifications require an HTTPS connection.';
          els.nextStepBox.innerHTML =
            '<strong>Step 1: Switch from plain HTTP to HTTPS</strong>' +
            '<p style="margin:8px 0 0 0;font-size:13.5px;">This page was opened at <code>' + escapeHtml(window.location.origin) + '</code>. iOS and Android block push notifications on unencrypted LAN addresses. Open your permanent HTTPS companion URL and scan the HTTPS QR code.</p>';
          els.nextStepBox.classList.remove('hidden');
          if (state.httpsPublicOrigin && state.httpsPublicOrigin.indexOf('https://') === 0) {
            els.openHttpsLinkBtn.href = state.httpsPublicOrigin + '/companion';
            els.openHttpsLinkBtn.classList.remove('hidden');
          }
          els.recheckSetupBtn.classList.remove('hidden');
        } else if (!r.homeScreenInstalled) {
          els.homeNotifStatusText.textContent =
            'Paired with ' + (state.hostDisplayName || 'your laptop') + '. Add WATSafe to your iPhone Home Screen once to enable lock-screen notifications.';
          const codeDisplay = state.handoffCode
            ? '<div class="transfer-code" id="handoffCodeDisplay">' + escapeHtml(state.handoffCode) + '</div>'
            : '<div style="font-size:13px;color:var(--muted);margin:8px 0;">Generating one-time setup code…</div>';
          els.nextStepBox.innerHTML =
            '<strong>Next step on iPhone: Add to Home Screen</strong>' +
            codeDisplay +
            '<ol>' +
            '<li>Tap <strong>Copy Home Screen setup code</strong> below.</li>' +
            '<li>Tap Safari’s <strong>Share</strong> button (square with upward arrow) and choose <strong>Add to Home Screen → Add</strong>.</li>' +
            '<li>Open the new <strong>WATSafe</strong> icon from your Home Screen and paste this code to enable notifications.</li>' +
            '</ol>';
          els.nextStepBox.classList.remove('hidden');
          els.copyHandoffBtn.classList.remove('hidden');
          if (!state.handoffCode) {
            ensureIosHandoffCode();
          }
        } else if (r.notificationPermission === 'denied') {
          els.homeNotifStatusText.textContent =
            'Notification permission is currently turned off for WATSafe on this phone.';
          const steps = r.isIos
            ? '<ol><li>Open iPhone <strong>Settings → Notifications → WATSafe</strong>.</li><li>Turn on <strong>Allow Notifications</strong> (enable Lock Screen &amp; Banners).</li><li>Return to WATSafe and tap <strong>Re-check notification setup</strong>.</li></ol>'
            : '<ol><li>Tap the site settings / lock icon in your browser bar.</li><li>Set <strong>Notifications</strong> to <strong>Allow</strong>.</li><li>Tap <strong>Re-check notification setup</strong> below.</li></ol>';
          els.nextStepBox.innerHTML =
            '<strong>Allow notifications in phone settings</strong>' + steps;
          els.nextStepBox.classList.remove('hidden');
          els.recheckSetupBtn.classList.remove('hidden');
        } else if (r.notificationPermission === 'default') {
          els.homeNotifStatusText.textContent =
            'Almost done! Tap Enable notifications below so ' + (state.hostDisplayName || 'your laptop') + ' can alert your lock screen.';
          els.nextStepBox.innerHTML =
            '<strong>Next step: Enable notifications</strong>' +
            '<p style="margin:6px 0 0 0;font-size:13.5px;">Tap the button below and choose <strong>Allow</strong> when your phone asks for permission.</p>';
          els.nextStepBox.classList.remove('hidden');
          els.enableNotifBtn.textContent = 'Enable notifications';
          els.enableNotifBtn.classList.remove('hidden');
        } else if (!r.pushSubscribed || !r.backendPushRegistered) {
          els.homeNotifStatusText.textContent =
            'Notification permission is granted — tap below to finish registering push delivery with WATSafe.';
          els.enableNotifBtn.textContent = 'Complete push registration';
          els.enableNotifBtn.classList.remove('hidden');
        } else {
          els.homeNotifStatusText.textContent =
            'Make sure your phone is running iOS 16.4+ or a modern Android browser to enable Web Push.';
          els.recheckSetupBtn.classList.remove('hidden');
        }
      }

      // Render all 5 separate readiness checks clearly
      const c1 = r.httpsReady ? 'ok' : 'blocked';
      const c2 = !r.httpsReady ? 'pending' : (r.homeScreenInstalled ? 'ok' : 'next');
      const c3 = (!r.httpsReady || !r.homeScreenInstalled)
        ? 'pending'
        : (r.notificationPermission === 'granted' ? 'ok' : (r.notificationPermission === 'denied' ? 'blocked' : 'next'));
      const c4 = c3 !== 'ok' ? 'pending' : (r.pushSubscribed ? 'ok' : 'next');
      const c5 = c4 !== 'ok' ? 'pending' : (r.backendPushRegistered ? 'ok' : 'next');

      els.readinessChecklist.innerHTML =
        renderChecklistItem(
          c1,
          '1. Secure HTTPS connection',
          r.httpsReady
            ? ('Connected securely (' + window.location.host + (isEphemeralTunnelHost() ? ' — temporary tunnel)' : ' — permanent origin)'))
            : 'Plain HTTP (' + window.location.host + ') — switch to https://'
        ) +
        renderChecklistItem(
          c2,
          r.homeScreenRequired ? '2. Added to iPhone Home Screen' : '2. App / browser readiness',
          r.homeScreenInstalled
            ? (r.isStandalone ? 'Running as installed Home Screen app' : 'Ready in mobile browser')
            : 'Tap Share in Safari → Add to Home Screen, then open the WATSafe icon'
        ) +
        renderChecklistItem(
          c3,
          '3. Notification permission',
          r.notificationPermission === 'granted'
            ? 'Allowed'
            : (r.notificationPermission === 'denied' ? 'Blocked in phone settings' : (c3 === 'next' ? 'Tap Enable notifications above' : 'Waiting for previous step'))
        ) +
        renderChecklistItem(
          c4,
          '4. Web Push subscription',
          r.pushSubscribed ? 'Active on this phone' : 'Created when notifications are enabled'
        ) +
        renderChecklistItem(
          c5,
          '5. Server push registration',
          r.backendPushRegistered ? 'Registered for ' + (state.hostDisplayName || 'paired laptop') : 'Pending subscription registration'
        );

      els.settingsDeliverySummary.textContent = els.homeNotifStatusText.textContent;
      els.settingsAddressSummary.textContent =
        'Companion origin: ' +
        window.location.origin +
        (isEphemeralTunnelHost()
          ? ' (temporary tunnel — migrate once to a permanent HTTPS address so restarts never break this Home Screen icon)'
          : ' (permanent address)') +
        ' · Last connected: ' +
        formatTime(state.lastConnectedAtIso);
      renderActivityEvents();
    }

    function renderActivityEvents() {
      els.eventsList.innerHTML = '';
      if (!state.events.length) {
        els.eventDetailCard.classList.add('hidden');
        els.eventsList.innerHTML = '<div class="card"><p style="margin:0;">No alarm events yet. Test alerts and real alarms from ' + escapeHtml(state.hostDisplayName || 'your laptop') + ' will appear here.</p></div>';
        return;
      }

      if (!selectedIncidentId && state.events.length > 0) {
        selectedIncidentId = state.events[0].incidentId;
      }

      if (selectedIncidentId) {
        const ev = state.events.find(e => e.incidentId === selectedIncidentId);
        if (ev) {
          let locHtml = '<p style="margin-top:8px;">Location unavailable — location access was off or unavailable on the protected device.</p>';
          if (ev.locationStatus === 'pending') {
            locHtml = '<p style="margin-top:8px;">Updating protected device location…</p>';
          } else if (ev.locationStatus === 'notRequested') {
            locHtml = '<p style="margin-top:8px;">Location sharing was turned off on the protected laptop when this event occurred.</p>';
          } else if (ev.location) {
            const loc = ev.location;
            const kindLabel = loc.isLastKnown
              ? 'Last known location'
              : ((loc.isApproximate || (loc.accuracyMeters && loc.accuracyMeters > 100)) ? 'Approximate location' : 'Precise location');
            const mapsHref = 'https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent(loc.latitude + ',' + loc.longitude);
            locHtml = '<div style="margin-top:12px;padding:12px;border-radius:10px;background:var(--bg);border:1px solid var(--border);">' +
              '<div style="font-weight:700;margin-bottom:4px;">' + escapeHtml(kindLabel) + '</div>' +
              '<div style="font-size:13px;color:var(--muted);margin-bottom:10px;">Recorded ' + escapeHtml(formatTime(loc.capturedAtUtc)) + ' (' + Number(loc.latitude).toFixed(5) + ', ' + Number(loc.longitude).toFixed(5) + ')</div>' +
              '<a class="btn btn-primary" target="_blank" rel="noopener" href="' + mapsHref + '">Open in Maps</a>' +
              '</div>';
          }
          els.eventDetailCard.innerHTML =
            '<span class="pill ' + (ev.isTest ? 'pill-warn' : 'pill-alert') + '">' + (ev.isTest ? 'Test alert' : 'Alarm triggered') + '</span>' +
            '<h2 style="margin-top:10px;">' + escapeHtml(ev.hostDisplayName || state.hostDisplayName) + '</h2>' +
            '<p style="margin-bottom:6px;">' + escapeHtml(formatTime(ev.triggeredAtUtc)) + '</p>' +
            '<p>' + escapeHtml(ev.triggerSummary || 'Alarm triggered') + '</p>' + locHtml;
          els.eventDetailCard.classList.remove('hidden');
        }
      } else {
        els.eventDetailCard.classList.add('hidden');
      }

      state.events.forEach(ev => {
        const div = document.createElement('div');
        div.className = 'event-item' + (ev.incidentId === selectedIncidentId ? ' selected' : '');
        const hasLoc = Boolean(ev.location);
        div.innerHTML =
          '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px;gap:8px;">' +
          '<strong>' + (ev.isTest ? 'Test alert' : 'Alarm triggered') + ' · ' + escapeHtml(ev.hostDisplayName || state.hostDisplayName) + '</strong>' +
          '<span style="font-size:12px;color:var(--muted);">' + escapeHtml(formatTime(ev.triggeredAtUtc)) + '</span>' +
          '</div>' +
          '<div style="font-size:13.5px;color:var(--muted);">' + escapeHtml(ev.triggerSummary || '') + '</div>' +
          (hasLoc
            ? '<div style="margin-top:8px;color:var(--amber);font-size:13px;font-weight:700;">View location →</div>'
            : '<div style="margin-top:6px;color:var(--subtle);font-size:12px;">Location ' + escapeHtml(ev.locationStatus === 'pending' ? 'updating…' : 'unavailable') + '</div>');
        div.addEventListener('click', () => {
          selectedIncidentId = ev.incidentId;
          renderConnectedUi();
        });
        els.eventsList.appendChild(div);
      });
    }

    async function fetchSingleIncidentIfMissing(incidentId) {
      if (!incidentId || !state.companionToken) return;
      if (state.events.some(e => e.incidentId === incidentId)) {
        renderConnectedUi();
        return;
      }
      try {
        const res = await fetch('/v1/companion/events/' + encodeURIComponent(incidentId), {
          headers: { 'Authorization': 'Bearer ' + state.companionToken }
        });
        if (await isAuthenticUnauthorizedSession(res)) {
          await handleServerRevokedSession();
          return;
        }
        if (isAuthenticWatSafeHeader(res) && res.ok) {
          const item = await res.json();
          state.seenIds[item.incidentId] = true;
          state.events.unshift(item);
          saveState();
          renderConnectedUi();
        }
      } catch (_) {}
    }

    function triggerFallbackForegroundNotification(ev) {
      const r = evaluateReadiness();
      // If real Web Push is active, the Service Worker push listener handles displaying the notification!
      if (r.notificationsEnabled) return;
      if (r.notificationPermission !== 'granted') return;
      const title = ev.hostDisplayName || state.hostDisplayName || 'WATSafe Alert';
      const body = ev.isTest ? 'Test alert — tap to view in Activity' : 'Alarm triggered — tap to view event';
      if (swRegistration && swRegistration.showNotification) {
        swRegistration.showNotification(title, {
          body: body,
          tag: 'watsafe-inc-' + ev.incidentId,
          renotify: false,
          data: { incidentId: ev.incidentId }
        }).catch(() => {});
      }
    }

    function computeNextPollDelayMs() {
      if (consecutiveFailures <= 0) return 3000;
      const base = Math.min(30000, 2000 * Math.pow(2, Math.min(consecutiveFailures - 1, 4)));
      const jitter = Math.round(base * (0.85 + Math.random() * 0.3));
      return jitter;
    }

    function scheduleNextPoll(overrideMs) {
      if (pollTimerId) {
        clearTimeout(pollTimerId);
        pollTimerId = null;
      }
      if (!state.companionToken) return;
      const delay = typeof overrideMs === 'number' ? overrideMs : computeNextPollDelayMs();
      pollTimerId = setTimeout(async () => {
        await pollAlerts();
        if (state.companionToken) {
          scheduleNextPoll();
        }
      }, delay);
    }

    let pollingInFlight = false;
    async function pollAlerts() {
      if (!state.companionToken || pollingInFlight) return;
      if (typeof navigator !== 'undefined' && navigator.onLine === false) {
        consecutiveFailures += 1;
        connState = 'service_unavailable';
        renderConnectedUi();
        return;
      }
      pollingInFlight = true;
      try {
        const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
        const timer = controller ? setTimeout(() => controller.abort(), 6000) : null;
        const res = await fetch(
          '/v1/companion/alerts?afterSeq=' + (state.lastSeq || 0),
          {
            headers: { 'Authorization': 'Bearer ' + state.companionToken },
            cache: 'no-store',
            signal: controller ? controller.signal : undefined
          }
        );
        if (timer) clearTimeout(timer);

        // Require pairing again ONLY on an authentic WATSafe 401 session revocation!
        if (await isAuthenticUnauthorizedSession(res)) {
          await handleServerRevokedSession();
          return;
        }

        // Non-WATSafe proxy pages (e.g. Cloudflare 530 / 502) or server 5xx keep pairing intact!
        if (!isAuthenticWatSafeHeader(res) || !res.ok) {
          consecutiveFailures += 1;
          connState = 'service_unavailable';
          renderConnectedUi();
          return;
        }

        const data = await res.json();
        consecutiveFailures = 0;
        if (data.hostDisplayName) state.hostDisplayName = data.hostDisplayName;
        if (data.vapidPublicKey) state.vapidPublicKey = data.vapidPublicKey;
        if (typeof data.backendPushRegistered === 'boolean') {
          state.backendPushRegistered = data.backendPushRegistered;
        }
        updateHostPresenceFromPayload(data);

        const incoming = Array.isArray(data.alerts) ? data.alerts : [];
        for (const item of incoming) {
          const seq = Math.max(item.alertSeq || 0, item.updatedSeq || 0);
          if (seq > state.lastSeq) state.lastSeq = seq;
          const existingIdx = state.events.findIndex(e => e.incidentId === item.incidentId);
          if (existingIdx >= 0) {
            state.events[existingIdx] = item;
          } else if (!state.seenIds[item.incidentId]) {
            state.seenIds[item.incidentId] = true;
            state.events.unshift(item);
            triggerFallbackForegroundNotification(item);
          }
        }
        if ((data.latestSeq || 0) > state.lastSeq) state.lastSeq = data.latestSeq;
        saveState();
        renderConnectedUi();
      } catch (_) {
        consecutiveFailures += 1;
        connState = 'service_unavailable';
        renderConnectedUi();
      } finally {
        pollingInFlight = false;
      }
    }

    async function triggerImmediateReconnect() {
      if (!state.companionToken) return;
      consecutiveFailures = 0;
      await maybeRefreshCompanionToken();
      await syncCompanionReadinessToBackend();
      scheduleNextPoll(0);
    }

    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible' && state.companionToken) {
        triggerImmediateReconnect();
      }
    });
    window.addEventListener('pageshow', () => {
      if (state.companionToken) {
        triggerImmediateReconnect();
      }
    });
    window.addEventListener('online', () => {
      if (state.companionToken) {
        connState = 'connecting';
        renderConnectedUi();
        triggerImmediateReconnect();
      } else {
        fetchServerRuntimeHealth();
      }
    });
    window.addEventListener('offline', () => {
      if (state.companionToken) {
        connState = 'service_unavailable';
        renderConnectedUi();
      }
    });
    if (navigator.connection && typeof navigator.connection.addEventListener === 'function') {
      navigator.connection.addEventListener('change', () => {
        if (state.companionToken) {
          triggerImmediateReconnect();
        }
      });
    }

    // Boot sequence: restore durable state immediately so offline Home Screen launches render instantly!
    (async function boot() {
      await hydrateDurableState();
      renderMigrationBanner();
      if (state.companionToken && !initialCode) {
        connState = 'connecting';
        enterConnectedShell();
      }
      await fetchServerRuntimeHealth();
      await ensureServiceWorkerAndInspectSubscription();
      if (initialCode) {
        await submitCodeOrHandoff(initialCode);
      } else if (state.companionToken) {
        await maybeRefreshCompanionToken();
        await ensureIosHandoffCode();
        await syncCompanionReadinessToBackend();
        if (selectedIncidentId) {
          fetchSingleIncidentIfMissing(selectedIncidentId);
        }
        scheduleNextPoll(0);
      } else {
        renderPrePairUi();
        hideAllSections();
        els.stepCodeEntry.classList.remove('hidden');
      }
    })();
  </script>
</body>
</html>''';
}
