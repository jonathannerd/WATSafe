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
    'iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAYAAAD0eNT6AAAQEElEQVR42u3bMU4rWxBFUQ8CIRFYIoHhMksiZ0jEMAGE7Kz77BWsCbRvVW2e/r88Pb/8AAAtFx8BAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAACAAAAABAAAIAABAAAAAAgAAEAAAgAAAAAQAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEwJTr6xsA/3ArBIBDD4AwEACOPgBiQAA4+gCIAQHg6APgRgkAhx9ACCAAHH4AIYAAcPwBRAACwOEHEAICAIMCIAIEgMMPgBAQAI4/ACJAADj+AIgAAeD4AyACBIDjD4AIEACOPwAiQAA4/gCIAAHg+AMgAgSA4w+ACBAAjj8AIkAAOP4AiAABIAAAEAACwPEHQASEA8DDBUAECAAAEADrAeDBAiACYgHgoQIgAgQAAAiA9QDwQAEQAQIAAATAegB4mACIAAEAAAJAAACAAJgLAA8SABEgAABAAAgAABAAcwHgIQIgAgQAAAgAAQAAAmAuADxAAESAAAAAASAAAEAACAAAEAACAAAEgAAAAAHg+APAdgQIAAAQAAIAAASAAAAAASAAAEAACAAABIAAEAAACAABIAAAEAACQAAAIAAEgAAAQAAIAAEAgAAQAAIAAAEgAAQAAAJAAAgAAASAAAAAASAAAEAACAAAEAACAAAEgAAAAAEgAABAAAgAABAAAgAABIAAgHP5/Hi/i28FAkAAwPChf5RvCwJAAMD4sRcFIAAEADj0wgAEgAAAh14YgAAQAODQCwMEgAAQAODYiwIEgAAQADj0CAMEgAAQADj0CAMEgAAQADj0CAMEgAAQADj2iAIEgAAQADj0CAMEgAAQADj0CAMEgAAQADj0CAMEgADAsQdRgAAQADj0IAwQAAIAhx6EAQJAAODQgzBAAAgAHHsQBQgAAYBDD8IAASAAcPBBECAABIAAAAQAAkAACABAACAABIAAAASAABAAAkAAAAJAAAgAASAAAAEgAASAABAAgAAQAAJAAAgAQAAIAAEgAAQAIAAEgAAQAAIAEAACQAAIAAEACAABIAAQAIAAEAACAAEAAsDOEgACAAHAncfBtxEACAABgOPgCPjt/fYIAAGAI2DZexPeBAJAAAgALHbvxDtBAAgAAYAF7v14PwJAAAgAAYBF7V15VwJAAAgAixpL2Vvz1gSAABAAlrLlizfoDQoAASAALF9LFm/T2xQAAkAAWLIWKt6r9yoABIAAsFAtTrxj71gACAABYHFakHjf3rcAEAAenQVpGeLNe/MCQABgGfqdMAtmQQAIAJaXnt8DM2JGBIAAILDcfH/MjJkRAAJAAFhmYGbMjAAQAFhmYGbMjAAQAFhmYGZ8fwEgALDMwMwgAAQAlhmYGQSAAMAyAzODABAAWGZgZhAAAgDLDMwMAkAAWGaWGZgZBIAAsMwsMzAzCAABYJlZZmBmBIAAEACWmWUGZkYACAABYJlZZpgZMyMABIAAsMwsM8yMmREAAkAAWGaWGWbGzAgAASAALDPLDDNjZgSAABAAlpllhpkxMwJAAAgAywzMjJkRAAIAywzMjJkRAAIAywzMjJkRAAIAywzMDAJAAGCZgZlBAAgALDMwMwgAAYBlBmYGASAAsMzAzCAABACWGZgZBIAAsMwsMzAzCAABYJlZZmBmBIAAEACWmWUGZkYACAABYJlZZpgZMyMABIAAsMwsM8yMmREAAkAAWGaWGWbGzAgAASAALDPLDDNjZgSAABAAlpllhpkxMwJAAAgAywzMjJkRAALAo7PMwMyYGQEgALDMwMyYGQEgALDMwMwgAAQAlhmYGQSAAMAyAzODABAAWGZgZhAAAgDLDMwMAkAAYJmBmUEACADLzDIDM4MAEACWmWUGZkYACAABYJlZZsf3/XX7k29jZhAAAgDLbPjQP8q3NDMIAAFgmVlmkaMvBswMAkAAYJk5/ELAzCAABIBlZpmVD78QMDMIAAFgmVlm4cMvBMwMAkAAWGaWWfz4iwAzIwAEgACwzCyz4OEXAmZGAAgAAWCZWWbx4y8CzIwAEAACwDKzzKLHXwSYGQEgAASAZWaZRY+/CDAzAkAACADLzDKLHv96BJgZASAABIBlZpllj385AsyMABAAAsAys8wEgJkxMwJAAAgAy8wyax3/agSYGQEgAASAZWaZ5Y9/MQLMjAAQAALAMrPMHP9gBJgZASAABIBlZpkJAAFgZgSAABAAlpll1j3+pQgwMwJAAAgAy8wyEwACwMwIAAEgACwzy6x9/CsRYGYEgAAQAJaZZSYABICZEQACQABYZpaZABAAZkYACAABYJmll1n1+BciwMwIAAEgACwzy0wACAAzIwAEgACwzCwzASAAzIwAEAACwDLLLrP68V+PADMjAASAALDMLDMBIADMjAAQAALAMrPMBIAAMDMCQAAIAMtMAAgAM2NmBIAAEACWmQAQAGbGzAgAASAALDMBIADMjJkRAAJAAFhmAkAAmBkBIAAEAJaZABAAZkYACAABgGUmAASAmREAAkAAYJkJAAFgZhAAAgDLTAAIADODABAAWGYCQACYGQSAAMAyEwACwMwgAAQAlpkAEABmBgEgALDMBIAAMDMIAAEgACwzEeD4mxkEgAAQAJaZABAAZkYACAABYJlZZgJAAJgZASAABIBlZpmJgN7xNzMCQAAIAMvMMhMAAsDMCAABIAAsM8tMAAgAMyMABIAAsMwss2gEmBkzIwAEgACwzCwzAWBmzIwAEAACwDLrLjPH38yYGQEgAASAZSYABICZMTMCQAAIAMtMBDj+ZsbMCAABIAAsMxHg+JsZMyMABACWmQAQAGZGAAgAAYBlJgIcfzODABAAWGYiwPE3MwgAAYBlJgIcfzODABAAWGYiwPE3MwgAAYBlJgIcfzODABAAWGYiwPE3MwgAAWCZWWgiwPE3LwgAAWChWWhCwOE3LwgAAWChWWjRCPBbmBcBIAAEgIVmqYVCwLc3KwgAAWCxWWqRGPCNzQkCQABYbBZbKAR8U3OCABAAFpvlNh4FvpUZQQAIACw3MCMIAAGABQdmAwEgACw5Sw7MBgJAAFhylhxmw2wIAAEgACw6iw4zYSYEgAAQAJadZYeZMBMCQAAIAMvOwsM8mAcBIAAEgKVn4WEWzIIAEAACwNKz+DAH5kAACAABYPlZfJgBMyAABIAAsPwsQLx/718ACAAsQUsQ7x4BIACwCMG7RwAIACxD8N4RAAIACxG8dwSAAMBSBO8cASAAGFiMliPeOAJAAOCvI/C+EQACAH8hgbeNABAAWJTgTSMABACWJXjTCAABgIUJ3jICQABw1qVpceIdIwAEAP5yAm8YASAAsEDB20UACAD8Eyp4twgAAYC/pPBmvVkEgADAX1N4r94rAkAAYKninXqnCAABgOWK9+l9CgABIACwYPE+vU8BIAAEAJYs3qV3KQAEgACwbC1bvEfvUQAIAAFg4Vq6eIveogAQAALA4rV08Q4RAAJAAFi+li/eHwJAAAgAC9gSxttDAAgALGKLGG8OASAAsJAtZLw1BIAAwGK2lPHOEAACAIvZcvbGvDEEgADAgragvS1vCwEgALCoLWpvyptCAAgALGwL21vylhAAAoD20ra4vSPvCAEgALC88X68HwSAAMA/3+LteDsCQAAIACxyvBlvRgAIAAGAf8rFe/HbCAABIACw1PFOEAACQABgueN9IAAEgADAkse7QAAIAAGAZY/3gAAQAAKAAy98S99b8BYEgAAQAFj8eAMIAAEgAHAA8NsjAASAAMAhwG+OABAAAgAHAb81AkAACAAcBvzGCAABIAA4+3FwIPy+CAABIADwFyJ+WwSAABAAOBT4TREAAkAA4GDgt0QACAABgMPhN/QbIgAEgADAAfHb+e0QAAJAAOCQ+M38ZggAAQAOit/Kb4UAEADg/yH3O/mdEAACAMfFcfH7+H0QAAIAR8aR8bv4XRAAAgDHxrHxe/g9EAACAEfH4fEbOP4IAAGAA+QA+fYgAAQADpFD5JuDABAAOEgOkm8NAkAA4DA5TL4xAkAACAAcKAfKt0UACAABgENVO1S+KQJAAAgAHKzYwfItEQACQAAgAmKHyzdEAAgAAYAIiB0w3w4BIAAEACIgdsh8MwSAABAAiIDYQfOtEAACQAAgAGKHzXcCASAAEAGx4+b7gAAQAIiA0KHzTUAACABEQOzg+RYgAAQAIiB2+HwDEAACABEQO4COPwgAAYAIiB1Cxx8EgACA2H8B7/CDABAAEDuOjj8IAAEAoX8e90/+IAAEAMQOpuMPAkAAQCwCHH8QAAIAYhHg+IMAEAAQiwDHHwSAAIBYBDj+IAAEAIgAxx8EgAAAEeD4gwAQACACHH8QAAIARIDjDwJAAIAIcPwRAAJAAIAIcPwRAAJAAIAIcPwRAAJAACACHHrHHwEgAAQAIgBvAgEgAAQAQsDhBwEgAAQAIsDxBwEgAAQAIsDxBwEgAEAEOP4gAAQAiADHHwSAAAAR4PiDABAAIAIcfxAAAgBEgOMPAkAAgAhw/EEACAAQAg4/CAABACLA8QcBIABABDj+IAAEAIgAxx8BIAAEAAQjwG+CABAAAgBiEeC3QAAIAAEAsQjwG4AAEAAQCgHfHASAAIBYBPjWIAAEAMQiwDcGASAAIBYBvi0IAAEAsQjwTUEACACIRYBvCQJAAEAoBHw7EAACAGIR4JuBABAAEIsA3woEgACAWAT4RiAABADEIsC3AQEgACAUAr4FCAABAAACQAAAgAAQAAAgAAQAAAgAAQCAABAAAgAAASAABAAAAkAACAAABIAAEAAACAABIAAAEAACQAAAIAAEgAAAQACEA0AEAOD4CwAAEAACAAAEgAAAAAEgAABAAAgAABAAIgAAto+/AAAAASAAAEAAiAAAmDz+AgAABIAAAAABIAIAYPL4CwAAEAACAAAEgAgAgMnjLwAAQACIAAAoHH8BAAACQAQAQOH4zwaACADA8RcAACAAKgEgAgBw/KMBIAIAcPwFAAAIgEoAiAAAHP9oAIgAABz/aACIAAAc/2gAiAAAHP9oAIgAAOrHPxsAIgCA8vFPB4AIAKB8A9MBIAIAHH8BIAIAcPwFgAgAwPEXAEIAAIdfAIgAABx/ASAEAHD4BYAIAMDxFwBCAACHXwAIAQAcfgEgBgBw9AWAGADA0RcAYgAAt0UACAMAhx4BAAAIAABAAAAAAgAAEAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAAAEAAAgAAEAAAAACAAAQAACAAAAABAAAIAAAQAD4EAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAgAAAAAQAACAAAQAAAAAIAABAAAIAAAAAEAAAIAB8BAAQAACAAAAABAAAIAABAAAAAAgAAOKpf8z7f17r49FMAAAAASUVORK5CYII=',
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
const SHELL_CACHE = 'watsafe-shell-2026.11.17-v5';
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
        const postSub = async (targetSub, vapidKey) => fetch('/v1/companion/push-subscription', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + saved.companionToken
          },
          body: JSON.stringify({
            endpoint: targetSub.endpoint,
            p256dh: arrayBufferToBase64UrlSw(targetSub.getKey('p256dh')),
            auth: arrayBufferToBase64UrlSw(targetSub.getKey('auth')),
            subscribedVapidPublicKey: vapidKey || undefined,
            httpsReady: true,
            homeScreenInstalled: true,
            notificationPermission: 'granted'
          })
        });
        let res = await postSub(sub, saved.vapidPublicKey);
        if (res && res.status === 409 && res.headers && res.headers.get('x-watsafe-companion') === '1') {
          const mismatchBody = await res.json().catch(() => null);
          if (mismatchBody && mismatchBody.vapidPublicKey && self.registration && self.registration.pushManager) {
            saved.vapidPublicKey = mismatchBody.vapidPublicKey;
            try { await sub.unsubscribe(); } catch (_) {}
            sub = await self.registration.pushManager.subscribe({
              userVisibleOnly: true,
              applicationServerKey: urlBase64ToUint8ArraySw(saved.vapidPublicKey)
            });
            res = await postSub(sub, saved.vapidPublicKey);
          }
        }
        if (isAuthenticWatSafeResponse(res)) {
          saved.pushEndpoint = sub.endpoint;
          saved.backendRegisteredEndpoint = sub.endpoint;
          saved.subscribedVapidPublicKey = saved.vapidPublicKey || null;
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
      (async () => {
        if (!payload.incidentId) return;
        try {
          const saved = await readIdbStateSw();
          if (saved && saved.companionToken) {
            await fetch('/v1/companion/events/' + encodeURIComponent(payload.incidentId) + '/ack', {
              method: 'POST',
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ' + saved.companionToken
              },
              body: JSON.stringify({ source: 'push_sw' })
            });
          }
        } catch (_) {}
      })(),
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
  <meta name="apple-mobile-web-app-status-bar-style" content="black">
  <meta name="apple-mobile-web-app-title" content="WATSafe">
  <link rel="icon" type="image/png" href="/favicon.png">
  <link rel="apple-touch-icon" sizes="180x180" href="/icons/apple-touch-icon.png">
  <link rel="manifest" href="/manifest.webmanifest">
  <link rel="stylesheet" href="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.css" crossorigin="anonymous">
  <script defer src="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.js" crossorigin="anonymous"></script>
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
      --phone-blue: #2563EB;
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
      padding-left: env(safe-area-inset-left, 0px);
      padding-right: env(safe-area-inset-right, 0px);
    }
    header {
      position: sticky;
      top: 0;
      z-index: 20;
      padding: calc(11px + env(safe-area-inset-top, 0px)) 16px 11px;
      border-bottom: 1px solid var(--border);
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 10px;
      background: rgba(20, 22, 25, 0.96);
      backdrop-filter: blur(8px);
      -webkit-backdrop-filter: blur(8px);
    }
    .brand { font-weight: 800; font-size: 17px; letter-spacing: 0.25px; display: flex; align-items: center; gap: 9px; white-space: nowrap; }
    .shield-dot { width: 11px; height: 11px; border-radius: 50%; background: var(--amber); display: inline-block; flex-shrink: 0; }
    main {
      flex: 1;
      max-width: 560px;
      width: 100%;
      margin: 0 auto;
      padding: 14px 16px calc(86px + env(safe-area-inset-bottom, 0px));
    }
    main.wide-devices { max-width: 960px; }
    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 18px;
      margin-bottom: 14px;
    }
    h1 { font-size: 21px; margin: 0 0 8px 0; line-height: 1.28; }
    h2 { font-size: 17px; margin: 0 0 6px 0; line-height: 1.3; }
    p { margin: 0 0 12px 0; color: var(--muted); line-height: 1.45; font-size: 14.5px; }
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
      min-height: 44px;
      width: 100%;
      padding: 12px 16px;
      border-radius: 12px;
      border: none;
      font-size: 15px;
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
      display: inline-flex;
      align-items: center;
      gap: 5px;
      padding: 4px 10px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
      line-height: 1.25;
    }
    .pill-ok { background: rgba(46,155,104,0.18); color: #6ee7b7; border: 1px solid var(--emerald); }
    .pill-warn { background: rgba(229,142,38,0.18); color: #fcd34d; border: 1px solid var(--amber); }
    .pill-alert { background: rgba(214,69,58,0.2); color: #fca5a5; border: 1px solid var(--crimson); }
    .pill-neutral { background: var(--elevated); color: var(--muted); border: 1px solid var(--border); }
    .pill-map-light { background: rgba(255,255,255,0.95); color: #0F172A; border: 1px solid rgba(15,23,42,0.18); box-shadow: 0 2px 6px rgba(15,23,42,0.12); }
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
      padding: 14px;
      margin: 12px 0;
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
      z-index: 20;
      background: var(--surface);
      border-top: 1px solid var(--border);
      display: flex;
      justify-content: space-around;
      padding: 8px 8px calc(8px + env(safe-area-inset-bottom, 0px));
    }
    .nav-btn {
      background: none; border: none; color: var(--muted);
      min-height: 40px;
      font-size: 13px; font-weight: 700; padding: 8px 14px; border-radius: 999px; cursor: pointer;
    }
    .nav-btn.active { background: rgba(229,142,38,0.2); color: var(--amber); }
    .devices-topbar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 10px;
      margin-bottom: 10px;
    }
    .device-chip-bar {
      display: flex;
      gap: 8px;
      overflow-x: auto;
      padding: 2px 0 10px;
      scrollbar-width: none;
      -webkit-overflow-scrolling: touch;
    }
    .device-chip-bar::-webkit-scrollbar { display: none; }
    .device-chip {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      min-height: 44px;
      padding: 8px 14px;
      border-radius: 999px;
      border: 1.5px solid var(--border);
      background: var(--surface);
      color: var(--text);
      font-size: 13.5px;
      font-weight: 700;
      white-space: nowrap;
      cursor: pointer;
      flex-shrink: 0;
    }
    .device-chip.selected {
      border-color: var(--amber);
      background: rgba(229, 142, 38, 0.16);
      color: #FDE68A;
    }
    .device-chip .chip-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      flex-shrink: 0;
    }
    .devices-grid {
      display: flex;
      flex-direction: column;
      gap: 12px;
    }
    @media (min-width: 720px), (orientation: landscape) and (min-width: 640px) {
      .devices-grid {
        display: grid;
        grid-template-columns: minmax(0, 1.35fr) minmax(280px, 0.95fr);
        align-items: start;
        gap: 14px;
      }
      .devices-grid .card { margin-bottom: 0; }
    }
    .map-card {
      padding: 8px;
      margin-bottom: 0;
    }
    .map-stage {
      position: relative;
      width: 100%;
      height: clamp(292px, 45vh, 430px);
      border-radius: 12px;
      overflow: hidden;
      border: 1px solid rgba(148, 163, 184, 0.35);
      background: #EEF2F6;
      touch-action: none;
    }
    .map-canvas {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
      display: block;
    }
    .map-vector-host {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
    }
    .map-overlay-top {
      position: absolute;
      top: 10px;
      left: 10px;
      right: 56px;
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      z-index: 4;
      pointer-events: none;
    }
    .map-controls {
      position: absolute;
      top: 10px;
      right: 10px;
      display: flex;
      flex-direction: column;
      gap: 6px;
      z-index: 5;
    }
    .map-ctrl-btn {
      width: 40px;
      height: 40px;
      border-radius: 10px;
      border: 1px solid rgba(15, 23, 42, 0.18);
      background: rgba(255, 255, 255, 0.95);
      color: #0F172A;
      font-size: 18px;
      font-weight: 800;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      box-shadow: 0 2px 8px rgba(15, 23, 42, 0.14);
    }
    .map-attrib {
      position: absolute;
      bottom: 6px;
      right: 8px;
      left: 8px;
      width: fit-content;
      margin-left: auto;
      max-width: calc(100% - 16px);
      z-index: 4;
      background: rgba(255, 255, 255, 0.9);
      color: #334155;
      border: 1px solid rgba(15, 23, 42, 0.1);
      font-size: 10px;
      padding: 2px 7px;
      border-radius: 5px;
      pointer-events: none;
    }
    .map-pin-wrap {
      display: flex;
      flex-direction: column;
      align-items: center;
      cursor: pointer;
      user-select: none;
    }
    .map-pin-badge {
      width: 34px;
      height: 34px;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      color: #FFFFFF;
      border: 2.5px solid #FFFFFF;
      box-shadow: 0 3px 10px rgba(15, 23, 42, 0.28);
      transition: transform 0.15s ease;
    }
    .map-pin-wrap.selected .map-pin-badge {
      transform: scale(1.12);
      box-shadow: 0 0 0 4px rgba(229, 142, 38, 0.42), 0 4px 12px rgba(15, 23, 42, 0.34);
    }
    .map-pin-label {
      margin-top: 3px;
      padding: 2px 7px;
      border-radius: 999px;
      background: rgba(255, 255, 255, 0.96);
      color: #0F172A;
      border: 1px solid rgba(15, 23, 42, 0.18);
      font-size: 11px;
      font-weight: 700;
      white-space: nowrap;
      max-width: 148px;
      overflow: hidden;
      text-overflow: ellipsis;
      box-shadow: 0 1px 4px rgba(15, 23, 42, 0.14);
    }
    .coords-disclosure {
      margin-top: 12px;
      border-top: 1px solid var(--border);
      padding-top: 10px;
      font-size: 12.5px;
      color: var(--muted);
    }
    .coords-disclosure summary {
      cursor: pointer;
      font-weight: 700;
      color: var(--subtle);
      padding: 4px 0;
      user-select: none;
    }
    .coords-disclosure .coords-mono {
      margin-top: 6px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12.5px;
      color: var(--text);
      user-select: all;
    }
    .btn-row {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      margin-top: 12px;
    }
    .btn-row .btn {
      flex: 1 1 136px;
      margin-top: 0;
      padding: 11px 14px;
      font-size: 14px;
    }
    .hidden { display: none !important; }
  </style>
</head>
<body>
  <header>
    <div class="brand"><span class="shield-dot" id="statusDot"></span> WATSafe</div>
    <span class="pill pill-warn" id="headerBadge">Connecting…</span>
  </header>
  <main id="appMain">
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

    <!-- Connected Devices Map Tab -->
    <section id="tabDevices" class="hidden">
      <div class="devices-topbar">
        <h1 style="margin:0;">Devices</h1>
        <button id="refreshDevicesBtn" class="btn btn-secondary" style="width:auto;min-height:40px;margin:0;padding:8px 14px;font-size:13.5px;">Refresh</button>
      </div>
      <div id="devicesRosterList" class="device-chip-bar" role="tablist" aria-label="Paired devices"></div>
      <div class="devices-grid">
        <div id="devicesMapWrap" class="card map-card">
          <div id="devicesMapStage" class="map-stage"></div>
        </div>
        <div id="selectedDeviceCard" class="card" style="padding:16px;"></div>
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
      <div class="card">
        <h2>This phone’s location</h2>
        <p id="settingsPhoneLocationStatus" style="font-size:13.5px;">Off — this phone’s position is not shared on the Devices map.</p>
        <p style="font-size:12.5px;color:var(--subtle);">When enabled, WATSafe updates this phone’s marker only while WATSafe is open on screen. Home Screen web apps cannot track phone GPS in the background.</p>
        <button id="togglePhoneLocationBtn" class="btn btn-secondary">Share this phone’s location</button>
      </div>
      <div class="card">
        <h2>Location privacy &amp; history</h2>
        <p style="font-size:13.5px;">Your protected laptop reports its own coordinates while armed and for up to 15 minutes after an alarm. Phone and laptop locations are stored separately and automatically deleted after 7 days.</p>
        <button id="deleteLocationHistoryBtn" class="btn btn-secondary">Delete stored location history</button>
      </div>
    </section>
  </main>

  <nav id="bottomNav" class="nav-bar hidden">
    <button class="nav-btn active" data-tab="Home">Home</button>
    <button class="nav-btn" data-tab="Devices">Devices</button>
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

    function getSubscriptionApplicationServerKey(sub) {
      if (!sub || !sub.options || !sub.options.applicationServerKey) return '';
      return arrayBufferToBase64Url(sub.options.applicationServerKey);
    }

    let state = {
      companionToken: null,
      pairingSessionId: null,
      deviceId: null,
      installationDeviceId: null,
      hostDisplayName: 'My Laptop',
      phoneDisplayName: detectPhoneName(),
      vapidPublicKey: null,
      subscribedVapidPublicKey: null,
      httpsPublicOrigin: null,
      permanentHttpsOrigin: null,
      pushEndpoint: null,
      backendRegisteredEndpoint: null,
      backendPushRegistered: false,
      pushSubscriptionNeedsRenewal: false,
      pushRepairNeeded: false,
      lastPushErrorCode: null,
      handoffCode: null,
      handoffExpiresAtUtc: null,
      tokenRefreshedAtIso: null,
      lastConnectedAtIso: null,
      hostOnline: true,
      hostLastSeenAtUtc: null,
      hostDisconnectedAtUtc: null,
      hostProtectionState: 'off',
      phoneLocationSharingEnabled: false,
      phoneLatestLocation: null,
      phoneLocationPermission: 'prompt',
      placeLabelCache: {},
      lastSeq: 0,
      seenIds: {},
      events: [],
      authorizedDevices: []
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
      tabDevices: document.getElementById('tabDevices'),
      tabActivity: document.getElementById('tabActivity'),
      tabSettings: document.getElementById('tabSettings'),
      bottomNav: document.getElementById('bottomNav'),
      devicesMapStage: document.getElementById('devicesMapStage'),
      selectedDeviceCard: document.getElementById('selectedDeviceCard'),
      devicesRosterList: document.getElementById('devicesRosterList'),
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
      settingsAddressSummary: document.getElementById('settingsAddressSummary'),
      settingsPhoneLocationStatus: document.getElementById('settingsPhoneLocationStatus'),
      togglePhoneLocationBtn: document.getElementById('togglePhoneLocationBtn'),
      appMain: document.getElementById('appMain')
    };
    els.phoneNameInput.value = state.phoneDisplayName || detectPhoneName();

    let activeLookupCode = '';
    let activeTab = 'Home';
    let selectedIncidentId = pendingEventId || null;
    let selectedDeviceId = null;
    let pendingTestIncidentId = null;
    let swRegistration = null;
    let activePushSubscription = null;
    let connState = 'connecting'; // 'connecting' | 'connected' | 'laptop_offline' | 'service_unavailable'
    let consecutiveFailures = 0;
    let pollTimerId = null;
    let phoneGeoWatchId = null;
    let lastPhoneGeoUploadMs = 0;
    const mapControllers = {};
    const pendingGeocodeKeys = {};

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
      [els.stepCodeEntry, els.stepConfirmPair, els.tabHome, els.tabDevices, els.tabActivity, els.tabSettings]
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

      const subAppKey = getSubscriptionApplicationServerKey(activePushSubscription) || state.subscribedVapidPublicKey || '';
      const vapidKeyMismatch = Boolean(
        subAppKey &&
        state.vapidPublicKey &&
        subAppKey !== state.vapidPublicKey
      );
      const needsPushRenewal = Boolean(
        vapidKeyMismatch ||
        state.pushSubscriptionNeedsRenewal ||
        state.pushRepairNeeded
      );

      const subscribedOk = Boolean(
        hasPushApis &&
        permission === 'granted' &&
        activePushSubscription &&
        state.pushEndpoint &&
        !vapidKeyMismatch
      );

      const backendOk = Boolean(
        subscribedOk &&
        state.backendPushRegistered &&
        state.backendRegisteredEndpoint === state.pushEndpoint &&
        !needsPushRenewal
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
        vapidKeyMismatch: vapidKeyMismatch,
        needsPushRenewal: needsPushRenewal,
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

    async function acknowledgeEventReceipt(incidentId, source) {
      if (!incidentId || !state.companionToken) return;
      try {
        const res = await fetch('/v1/companion/events/' + encodeURIComponent(incidentId) + '/ack', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + state.companionToken
          },
          body: JSON.stringify({ source: source || 'companion_poll' })
        });
        if (isAuthenticWatSafeHeader(res) && res.ok) {
          const ackBody = await res.json();
          const idx = state.events.findIndex(e => e.incidentId === incidentId);
          if (idx >= 0) {
            state.events[idx].receiptConfirmed = true;
            state.events[idx].receiptConfirmedAtUtc = ackBody.receiptConfirmedAtUtc || new Date().toISOString();
            state.events[idx].receiptSource = ackBody.receiptSource || source || 'companion_poll';
            saveState();
          }
          if (pendingTestIncidentId && pendingTestIncidentId === incidentId) {
            pendingTestIncidentId = null;
            showInfo('Phone receipt confirmed — test notification arrived on this phone.');
          }
        }
      } catch (_) {}
    }

    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.addEventListener('message', async (ev) => {
        if (!ev.data) return;
        if (ev.data.type === 'PUSH_RECEIVED' && ev.data.incidentId) {
          state.seenIds[ev.data.incidentId] = true;
          const idx = state.events.findIndex(e => e.incidentId === ev.data.incidentId);
          if (idx >= 0) {
            state.events[idx].receiptConfirmed = true;
            state.events[idx].receiptSource = 'push_sw';
          }
          if (pendingTestIncidentId && pendingTestIncidentId === ev.data.incidentId) {
            pendingTestIncidentId = null;
            showInfo('Phone receipt confirmed — test notification arrived on this phone.');
          }
          saveState();
          triggerImmediateReconnect();
        }
        if ((ev.data.type === 'OPEN_INCIDENT' || ev.data.type === 'OPEN_INCIDENT_MAP') && ev.data.incidentId) {
          selectedIncidentId = ev.data.incidentId;
          try { window.history.replaceState({}, '', '/companion?event=' + encodeURIComponent(selectedIncidentId)); } catch (_) {}
          switchTab('Activity');
          fetchSingleIncidentIfMissing(selectedIncidentId);
        }
        if (ev.data.type === 'PUSH_SUBSCRIPTION_RENEWED' && ev.data.endpoint) {
          state.pushEndpoint = ev.data.endpoint;
          state.backendRegisteredEndpoint = ev.data.endpoint;
          state.backendPushRegistered = true;
          state.pushSubscriptionNeedsRenewal = false;
          state.pushRepairNeeded = false;
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

      // Automatic push subscription renewal & VAPID key mismatch recovery while keeping pairing intact!
      if (r.httpsReady && r.homeScreenInstalled && r.notificationPermission === 'granted') {
        if (!state.vapidPublicKey) {
          await fetchServerRuntimeHealth();
          r = evaluateReadiness();
        }
        if (activePushSubscription && (r.vapidKeyMismatch || state.pushSubscriptionNeedsRenewal)) {
          try { await activePushSubscription.unsubscribe(); } catch (_) {}
          activePushSubscription = null;
          state.pushEndpoint = null;
          state.backendRegisteredEndpoint = null;
          state.backendPushRegistered = false;
          state.subscribedVapidPublicKey = null;
          state.pushSubscriptionNeedsRenewal = false;
          saveState();
          r = evaluateReadiness();
        }
        if (!activePushSubscription && swRegistration && swRegistration.pushManager && state.vapidPublicKey) {
          try {
            activePushSubscription = await swRegistration.pushManager.subscribe({
              userVisibleOnly: true,
              applicationServerKey: urlBase64ToUint8Array(state.vapidPublicKey)
            });
            state.pushEndpoint = activePushSubscription ? activePushSubscription.endpoint : null;
            state.pushRepairNeeded = false;
            saveState();
            r = evaluateReadiness();
          } catch (_) {
            state.pushRepairNeeded = true;
            saveState();
            r = evaluateReadiness();
          }
        }
        if (activePushSubscription) {
          const p256dh = arrayBufferToBase64Url(activePushSubscription.getKey('p256dh'));
          const auth = arrayBufferToBase64Url(activePushSubscription.getKey('auth'));
          if (p256dh && auth && (!state.backendPushRegistered || state.backendRegisteredEndpoint !== activePushSubscription.endpoint || r.needsPushRenewal)) {
            try {
              await registerPushSubscriptionWithBackend(activePushSubscription, p256dh, auth, true);
              return;
            } catch (_) {}
          }
        }
      }

      const channel = r.notificationsEnabled
        ? 'web_push'
        : (!r.httpsReady
            ? 'needs_https'
            : (!r.homeScreenInstalled
                ? 'needs_home_screen'
                : (r.notificationPermission === 'denied'
                    ? 'denied'
                    : (r.needsPushRenewal ? 'needs_push_renewal' : 'foreground_only'))));

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
            subscribedVapidPublicKey: getSubscriptionApplicationServerKey(activePushSubscription) || state.subscribedVapidPublicKey || undefined,
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
          state.pushSubscriptionNeedsRenewal = Boolean(updated.pushSubscriptionNeedsRenewal);
          state.lastPushErrorCode = updated.lastPushErrorCode || null;
          if (updated.vapidPublicKey) state.vapidPublicKey = updated.vapidPublicKey;
          updateHostPresenceFromPayload(updated);
          consecutiveFailures = 0;
          saveState();
        }
      } catch (_) {}
      renderConnectedUi();
    }

    async function registerPushSubscriptionWithBackend(sub, p256dh, auth, allowMismatchRetry) {
      const r = evaluateReadiness();
      const subAppKey = getSubscriptionApplicationServerKey(sub) || state.vapidPublicKey || '';
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
          subscribedVapidPublicKey: subAppKey || undefined,
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
      if (res.status === 409 && body && body.error === 'VAPID_KEY_MISMATCH' && body.vapidPublicKey && allowMismatchRetry !== false) {
        state.vapidPublicKey = body.vapidPublicKey;
        try { await sub.unsubscribe(); } catch (_) {}
        activePushSubscription = null;
        if (swRegistration && swRegistration.pushManager) {
          const renewed = await swRegistration.pushManager.subscribe({
            userVisibleOnly: true,
            applicationServerKey: urlBase64ToUint8Array(state.vapidPublicKey)
          });
          activePushSubscription = renewed;
          const nextP256dh = arrayBufferToBase64Url(renewed.getKey('p256dh'));
          const nextAuth = arrayBufferToBase64Url(renewed.getKey('auth'));
          if (nextP256dh && nextAuth) {
            return await registerPushSubscriptionWithBackend(renewed, nextP256dh, nextAuth, false);
          }
        }
      }
      if (!res.ok) {
        throw new Error(body.message || 'Server rejected push subscription registration.');
      }
      state.pushEndpoint = sub.endpoint;
      state.backendRegisteredEndpoint = sub.endpoint;
      state.subscribedVapidPublicKey = subAppKey || state.vapidPublicKey || null;
      state.backendPushRegistered = Boolean(body.backendPushRegistered);
      state.pushSubscriptionNeedsRenewal = false;
      state.pushRepairNeeded = false;
      state.lastPushErrorCode = null;
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

        // 3. Create or refresh Web Push subscription (replace stale/mismatched subscription cleanly)
        let sub = await readyReg.pushManager.getSubscription();
        const existingKey = getSubscriptionApplicationServerKey(sub);
        if (sub && (state.pushSubscriptionNeedsRenewal || state.pushRepairNeeded || (existingKey && existingKey !== state.vapidPublicKey))) {
          try { await sub.unsubscribe(); } catch (_) {}
          sub = null;
        }
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
        await registerPushSubscriptionWithBackend(sub, p256dh, auth, true);
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
        const pushAccepted = Boolean(
          body.pushAccepted ||
          Number(body.pushAcceptedCount ?? body.pushDispatchedCount ?? 0) > 0
        );
        if (body.receiptConfirmed) {
          pendingTestIncidentId = null;
          showInfo('Phone receipt confirmed — test notification arrived on this phone.');
        } else if (pushAccepted) {
          pendingTestIncidentId = body.incidentId || null;
          showInfo(
            'Push service accepted test alert — waiting for phone receipt (check your lock screen or notification banner).'
          );
        } else {
          pendingTestIncidentId = null;
          showInfo('');
          const failedCount = Number(body.pushFailedCount || 0);
          const reasons = Array.isArray(body.pushFailureReasons) && body.pushFailureReasons.length
            ? (' (' + body.pushFailureReasons.join(', ') + ')')
            : '';
          if (failedCount > 0) {
            showError(
              'Push provider rejected the test alert' +
                reasons +
                '. Recorded in Activity only — tap Repair notifications below to refresh push delivery.'
            );
          } else {
            showError(
              'Notifications are not active on this phone yet — test alert was recorded in Activity only. Complete the notification step below.'
            );
          }
          await syncCompanionReadinessToBackend();
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
    document.getElementById('refreshDevicesBtn').addEventListener('click', () => {
      fetchAuthorizedDevicesLocations(true);
    });
    if (els.togglePhoneLocationBtn) {
      els.togglePhoneLocationBtn.addEventListener('click', () => {
        if (state.phoneLocationSharingEnabled) {
          disableCompanionPhoneLocationSharing(true);
        } else {
          enableCompanionPhoneLocationSharing(true);
        }
      });
    }
    document.getElementById('deleteLocationHistoryBtn').addEventListener('click', async () => {
      if (!state.companionToken) return;
      stopForegroundPhoneLocationWatch();
      state.phoneLocationSharingEnabled = false;
      state.phoneLatestLocation = null;
      try {
        const res = await fetch('/v1/location-history', {
          method: 'DELETE',
          headers: { 'Authorization': 'Bearer ' + state.companionToken }
        });
        state.events = state.events.map(ev => Object.assign({}, ev, {
          location: null,
          alarmLocation: null,
          locationTrail: [],
          locationStatus: 'notRequested',
          locationTrackingState: 'stopped'
        }));
        state.authorizedDevices = (state.authorizedDevices || []).map(d => Object.assign({}, d, {
          latestLocation: null,
          alarmLocation: null,
          locationTrail: [],
          locationSharingEnabled: false,
          locationStatus: 'notRequested',
          trackingState: 'unavailable',
          statusExplanation: 'Stored location history was deleted.'
        }));
        saveState();
        renderConnectedUi();
        if (isAuthenticWatSafeHeader(res) && res.ok) {
          showInfo('Stored location history deleted from this phone and your WATSafe session.');
        } else {
          showInfo('Local location history cleared.');
        }
      } catch (_) {
        showError('Could not reach relay right now — local cached location history cleared.');
      }
    });
    els.retryConnectionBtn.addEventListener('click', () => {
      showError('');
      connState = 'connecting';
      renderConnectedUi();
      triggerImmediateReconnect();
    });

    document.getElementById('disconnectPhoneBtn').addEventListener('click', async () => {
      stopForegroundPhoneLocationWatch();
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
      state.phoneLocationSharingEnabled = false;
      state.phoneLatestLocation = null;
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
      if (els.appMain) {
        els.appMain.classList.toggle('wide-devices', tab === 'Devices');
      }
      hideAllSections();
      if (tab === 'Home') els.tabHome.classList.remove('hidden');
      if (tab === 'Devices') {
        els.tabDevices.classList.remove('hidden');
        fetchAuthorizedDevicesLocations(false);
      }
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
      if (s === 'interrupted') return 'Protection interrupted';
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
        } else if (r.needsPushRenewal || !r.pushSubscribed || !r.backendPushRegistered) {
          if (r.needsPushRenewal || state.lastPushErrorCode) {
            els.homeNotifStatusText.textContent =
              'Your phone pairing is active, but lock-screen push delivery needs a one-tap refresh.';
            els.nextStepBox.innerHTML =
              '<strong>Refresh push notifications</strong>' +
              '<p style="margin:6px 0 0 0;font-size:13.5px;">Tap <strong>Repair notifications</strong> once below to renew your push subscription. You do not need to reinstall WATSafe or scan a new QR code.</p>';
            els.nextStepBox.classList.remove('hidden');
            els.enableNotifBtn.textContent = 'Repair notifications';
            els.enableNotifBtn.classList.remove('hidden');
          } else {
            els.homeNotifStatusText.textContent =
              'Notification permission is granted — tap below to finish registering push delivery with WATSafe.';
            els.enableNotifBtn.textContent = 'Complete push registration';
            els.enableNotifBtn.classList.remove('hidden');
          }
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
      renderPhoneLocationSettingsCard();
      renderDevicesTab();
      renderActivityEvents();
    }

    function isValidCoord(loc) {
      if (!loc || typeof loc !== 'object') return false;
      const lat = Number(loc.latitude);
      const lon = Number(loc.longitude);
      if (!isFinite(lat) || !isFinite(lon)) return false;
      if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return false;
      if (Math.abs(lat) < 0.000001 && Math.abs(lon) < 0.000001) return false;
      if (loc.accuracyMeters !== undefined && loc.accuracyMeters !== null) {
        const acc = Number(loc.accuracyMeters);
        if (!isFinite(acc) || acc < 0) return false;
      }
      return true;
    }

    function haversineMeters(a, b) {
      if (!isValidCoord(a) || !isValidCoord(b)) return 0;
      const toRad = d => d * Math.PI / 180;
      const dLat = toRad(Number(b.latitude) - Number(a.latitude));
      const dLon = toRad(Number(b.longitude) - Number(a.longitude));
      const lat1 = toRad(Number(a.latitude));
      const lat2 = toRad(Number(b.latitude));
      const s = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * (Math.sin(dLon / 2) ** 2);
      return 6371000 * 2 * Math.atan2(Math.sqrt(s), Math.sqrt(Math.max(0, 1 - s)));
    }

    function differsMeaningfully(a, b) {
      if (!isValidCoord(a) || !isValidCoord(b)) return false;
      const dist = haversineMeters(a, b);
      const acc = Number(a.accuracyMeters || 35) + Number(b.accuracyMeters || 35);
      return dist >= Math.max(25, acc * 0.65);
    }

    function formatRelativeAge(iso, isLastKnown) {
      if (!iso) return 'Update time unavailable';
      const ts = new Date(iso).getTime();
      if (isNaN(ts)) return isLastKnown ? 'Last known recently' : 'Updated recently';
      const sec = Math.max(0, Math.round((Date.now() - ts) / 1000));
      const prefix = isLastKnown ? 'Last known · ' : 'Updated ';
      if (sec < 60) return isLastKnown ? 'Last known · just now' : 'Just now';
      const min = Math.max(1, Math.floor(sec / 60));
      if (min === 1) return prefix + '1 minute ago';
      if (min < 60) return prefix + min + ' minutes ago';
      const hr = Math.floor(min / 60);
      if (hr === 1) return prefix + '1 hour ago';
      if (hr < 24) return prefix + hr + ' hours ago';
      const days = Math.floor(hr / 24);
      return prefix + days + (days === 1 ? ' day ago' : ' days ago');
    }

    function formatAccuracyLabel(loc) {
      if (!loc) return 'Location unavailable';
      const acc = Number(loc.accuracyMeters);
      if (isFinite(acc) && acc > 0) {
        if (loc.isApproximate || acc > 100) return 'Approximate (±' + Math.round(acc) + ' m)';
        return '±' + Math.round(acc) + ' m';
      }
      return loc.isApproximate ? 'Approximate location' : 'Precise location';
    }

    function trackingBadgeMeta(rawTracking) {
      if (connState === 'service_unavailable') {
        return { label: 'Reconnecting', cls: 'pill-warn' };
      }
      if (rawTracking === 'live') {
        return { label: 'Live', cls: 'pill-ok' };
      }
      if (rawTracking === 'reconnecting') {
        return { label: 'Reconnecting', cls: 'pill-warn' };
      }
      return { label: 'Last known location', cls: 'pill-map-light' };
    }

    function getReadableLocationSummary(loc) {
      if (!isValidCoord(loc)) return 'Location unavailable';
      const key = Number(loc.latitude).toFixed(3) + ',' + Number(loc.longitude).toFixed(3);
      if (state.placeLabelCache && state.placeLabelCache[key]) {
        return state.placeLabelCache[key];
      }
      if (!pendingGeocodeKeys[key] && typeof navigator !== 'undefined' && navigator.onLine !== false) {
        pendingGeocodeKeys[key] = true;
        fetch(
          'https://nominatim.openstreetmap.org/reverse?format=jsonv2&zoom=16&lat=' +
            encodeURIComponent(Number(loc.latitude).toFixed(3)) +
            '&lon=' +
            encodeURIComponent(Number(loc.longitude).toFixed(3)),
          { headers: { 'Accept-Language': 'en' } }
        )
          .then(r => (r && r.ok ? r.json() : null))
          .then(data => {
            if (!data || typeof data !== 'object') return;
            const addr = data.address || {};
            const primary = addr.road || addr.pedestrian || addr.neighbourhood || addr.suburb || data.name || '';
            const secondary = addr.city || addr.town || addr.village || addr.municipality || addr.county || '';
            const label = [primary, secondary].filter(Boolean).join(', ');
            if (label) {
              if (!state.placeLabelCache) state.placeLabelCache = {};
              state.placeLabelCache[key] = label;
              saveState();
              renderDevicesTab();
            }
          })
          .catch(() => {});
      }
      return (loc.isApproximate || Number(loc.accuracyMeters || 0) > 100)
        ? 'Approximate area'
        : 'Reported map position';
    }

    function stopForegroundPhoneLocationWatch() {
      if (phoneGeoWatchId !== null && typeof navigator !== 'undefined' && navigator.geolocation) {
        try { navigator.geolocation.clearWatch(phoneGeoWatchId); } catch (_) {}
      }
      phoneGeoWatchId = null;
    }

    async function uploadCompanionPhoneLocationSnapshot(snap, statusOverride, keepalive) {
      if (!state.companionToken) return;
      const body = {
        sharingEnabled: Boolean(state.phoneLocationSharingEnabled),
        locationStatus: statusOverride || (snap ? 'attached' : 'pending')
      };
      if (snap && isValidCoord(snap)) {
        body.location = {
          latitude: Number(snap.latitude),
          longitude: Number(snap.longitude),
          accuracyMeters: Number(snap.accuracyMeters || 35),
          capturedAt: snap.capturedAtUtc || snap.capturedAt || new Date().toISOString(),
          isApproximate: Boolean(snap.isApproximate),
          isLastKnown: Boolean(snap.isLastKnown)
        };
      }
      try {
        const res = await fetch('/v1/companion/location', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + state.companionToken
          },
          body: JSON.stringify(body),
          keepalive: Boolean(keepalive)
        });
        if (isAuthenticWatSafeHeader(res) && res.ok) {
          fetchAuthorizedDevicesLocations(false);
        }
      } catch (_) {}
    }

    function handlePhoneGeoPosition(pos, forceUpload) {
      if (!pos || !pos.coords) return;
      const acc = isFinite(pos.coords.accuracy) && pos.coords.accuracy > 0
        ? Number(pos.coords.accuracy)
        : 35;
      const candidate = {
        latitude: Number(pos.coords.latitude),
        longitude: Number(pos.coords.longitude),
        accuracyMeters: acc,
        capturedAtUtc: new Date(pos.timestamp || Date.now()).toISOString(),
        isApproximate: acc > 100,
        isLastKnown: false
      };
      if (!isValidCoord(candidate)) return;
      const prev = state.phoneLatestLocation;
      const nowMs = Date.now();
      const movedMeters = isValidCoord(prev) ? haversineMeters(prev, candidate) : 9999;
      const accImproved = isValidCoord(prev) && acc + 10 < Number(prev.accuracyMeters || 999);
      state.phoneLatestLocation = candidate;
      state.phoneLocationPermission = 'granted';
      saveState();
      if (forceUpload || nowMs - lastPhoneGeoUploadMs >= 12000 && (movedMeters >= 12 || accImproved || !prev)) {
        lastPhoneGeoUploadMs = nowMs;
        uploadCompanionPhoneLocationSnapshot(candidate, 'attached', false);
      } else {
        renderDevicesTab();
      }
    }

    function startForegroundPhoneLocationWatch() {
      if (!state.phoneLocationSharingEnabled) return;
      if (document.visibilityState === 'hidden') return;
      if (typeof navigator === 'undefined' || !navigator.geolocation || !isHttpsReady()) return;
      if (phoneGeoWatchId !== null) return;
      try {
        phoneGeoWatchId = navigator.geolocation.watchPosition(
          pos => handlePhoneGeoPosition(pos, false),
          err => {
            if (err && err.code === 1) {
              stopForegroundPhoneLocationWatch();
              state.phoneLocationPermission = 'denied';
              state.phoneLocationSharingEnabled = false;
              saveState();
              uploadCompanionPhoneLocationSnapshot(null, 'permissionDenied', false);
              renderPhoneLocationSettingsCard();
              renderDevicesTab();
            }
          },
          { enableHighAccuracy: true, maximumAge: 15000, timeout: 15000 }
        );
      } catch (_) {}
    }

    function enableCompanionPhoneLocationSharing(showFeedback) {
      if (!isHttpsReady() || typeof navigator === 'undefined' || !navigator.geolocation) {
        state.phoneLocationPermission = 'unsupported';
        saveState();
        showError('Browser geolocation requires HTTPS and Location Services enabled on this phone.');
        renderPhoneLocationSettingsCard();
        renderDevicesTab();
        return;
      }
      state.phoneLocationSharingEnabled = true;
      saveState();
      renderPhoneLocationSettingsCard();
      renderDevicesTab();
      navigator.geolocation.getCurrentPosition(
        pos => {
          lastPhoneGeoUploadMs = 0;
          handlePhoneGeoPosition(pos, true);
          startForegroundPhoneLocationWatch();
          renderPhoneLocationSettingsCard();
          if (showFeedback) {
            showInfo('Sharing this phone’s foreground location while WATSafe is open.');
          }
        },
        err => {
          stopForegroundPhoneLocationWatch();
          if (err && err.code === 1) {
            state.phoneLocationPermission = 'denied';
            state.phoneLocationSharingEnabled = false;
            saveState();
            uploadCompanionPhoneLocationSnapshot(null, 'permissionDenied', false);
            showError('Location permission is turned off for WATSafe. Allow Location in iOS Settings → Safari / Location Services, then try again.');
          } else {
            showError('Could not determine this phone’s current position right now. Try again with a clear Wi-Fi or GPS signal.');
          }
          renderPhoneLocationSettingsCard();
          renderDevicesTab();
        },
        { enableHighAccuracy: true, maximumAge: 10000, timeout: 12000 }
      );
    }

    async function disableCompanionPhoneLocationSharing(showFeedback) {
      stopForegroundPhoneLocationWatch();
      state.phoneLocationSharingEnabled = false;
      state.phoneLatestLocation = null;
      saveState();
      if (state.companionToken) {
        try {
          await fetch('/v1/companion/location', {
            method: 'DELETE',
            headers: { 'Authorization': 'Bearer ' + state.companionToken }
          });
          await fetchAuthorizedDevicesLocations(false);
        } catch (_) {}
      }
      renderPhoneLocationSettingsCard();
      renderDevicesTab();
      if (showFeedback) {
        showInfo('Stopped sharing this phone’s location.');
      }
    }

    function renderPhoneLocationSettingsCard() {
      if (!els.settingsPhoneLocationStatus || !els.togglePhoneLocationBtn) return;
      if (state.phoneLocationSharingEnabled) {
        const age = isValidCoord(state.phoneLatestLocation)
          ? (' · ' + formatRelativeAge(state.phoneLatestLocation.capturedAtUtc, false))
          : ' · Waiting for GPS fix…';
        els.settingsPhoneLocationStatus.textContent =
          'On while WATSafe is open' + age;
        els.togglePhoneLocationBtn.textContent = 'Stop sharing this phone’s location';
        els.togglePhoneLocationBtn.className = 'btn btn-danger';
      } else if (state.phoneLocationPermission === 'denied') {
        els.settingsPhoneLocationStatus.textContent =
          'Blocked — Location permission is turned off in browser or iOS Settings.';
        els.togglePhoneLocationBtn.textContent = 'Retry sharing phone location';
        els.togglePhoneLocationBtn.className = 'btn btn-secondary';
      } else {
        els.settingsPhoneLocationStatus.textContent =
          'Off — this phone’s position is not shared on the Devices map.';
        els.togglePhoneLocationBtn.textContent = 'Share this phone’s location';
        els.togglePhoneLocationBtn.className = 'btn btn-primary';
      }
    }

    function mercatorProject(lat, lon, worldSize) {
      const clamped = Math.max(-85.0511, Math.min(85.0511, Number(lat)));
      const sinLat = Math.sin(clamped * Math.PI / 180);
      const x = ((Number(lon) + 180) / 360) * worldSize;
      const y = (0.5 - Math.log((1 + sinLat) / (1 - sinLat)) / (4 * Math.PI)) * worldSize;
      return { x: x, y: y };
    }

    function mercatorUnproject(wx, wy, worldSize) {
      const lon = (wx / worldSize) * 360 - 180;
      const n = Math.PI - (2 * Math.PI * wy) / worldSize;
      const lat = (180 / Math.PI) * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n)));
      return { lat: Math.max(-85, Math.min(85, lat)), lon: (((lon + 180) % 360) + 360) % 360 - 180 };
    }

    function deviceSvgIcon(role, size) {
      const px = size || 16;
      if (role === 'protected_device') {
        return '<svg width="' + px + '" height="' + px + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="12" rx="2"></rect><path d="M1 19h22"></path></svg>';
      }
      return '<svg width="' + px + '" height="' + px + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="6" y="2" width="12" height="20" rx="2.5"></rect><path d="M11 18h2"></path></svg>';
    }

    function computeMarkerPixelOffsets(markers) {
      const offsets = markers.map(() => ({ x: 0, y: 0, coLocated: false }));
      for (let i = 0; i < markers.length; i++) {
        if (offsets[i].assigned) continue;
        const group = [i];
        for (let j = i + 1; j < markers.length; j++) {
          if (haversineMeters(markers[i].location, markers[j].location) < 28) {
            group.push(j);
          }
        }
        if (group.length >= 2) {
          const r = group.length === 2 ? 28 : 32;
          group.forEach((idx, k) => {
            const angle = -Math.PI / 4 + (k * 2 * Math.PI) / group.length;
            const oy = Math.round(Math.sin(angle) * r * 0.78);
            offsets[idx] = {
              x: Math.round(Math.cos(angle) * r),
              y: oy,
              labelAbove: oy < -4,
              coLocated: true,
              assigned: true
            };
          });
        } else {
          offsets[i].assigned = true;
        }
      }
      return offsets;
    }

    function destroyMapController(mapKey) {
      const prev = mapControllers[mapKey];
      if (!prev) return;
      if (Array.isArray(prev.mlMarkers)) {
        prev.mlMarkers.forEach(m => { try { m.remove(); } catch (_) {} });
      }
      if (prev.mlMap) {
        try { prev.mlMap.remove(); } catch (_) {}
      }
      delete mapControllers[mapKey];
    }

    function mountInteractiveMap(stageEl, mapKey, opts) {
      if (!stageEl || !opts || !isValidCoord(opts.primary)) return null;
      const existing = mapControllers[mapKey];
      if (existing && existing.stageEl === stageEl && stageEl.contains(existing.canvas)) {
        existing.update(opts);
        return existing;
      }
      destroyMapController(mapKey);

      const initialAcc = Number(opts.primary.accuracyMeters || (opts.primary.isApproximate ? 180 : 25));
      let zoom = initialAcc >= 600 ? 13.0 : (initialAcc >= 180 ? 14.3 : 15.6);
      let centerLat = Number(opts.primary.latitude);
      let centerLon = Number(opts.primary.longitude);

      stageEl.innerHTML =
        '<canvas class="map-canvas"></canvas>' +
        '<div class="map-vector-host"></div>' +
        '<div class="map-overlay-top"></div>' +
        '<div class="map-controls">' +
        '<button type="button" class="map-ctrl-btn" data-act="in" title="Zoom in">+</button>' +
        '<button type="button" class="map-ctrl-btn" data-act="out" title="Zoom out">−</button>' +
        '</div>' +
        '<div class="map-attrib">OpenFreeMap © OpenMapTiles · Data © OpenStreetMap contributors</div>';

      const canvas = stageEl.querySelector('.map-canvas');
      const vectorHost = stageEl.querySelector('.map-vector-host');
      const overlayTop = stageEl.querySelector('.map-overlay-top');

      const ctrl = {
        stageEl: stageEl,
        canvas: canvas,
        mlMap: null,
        mlReady: false,
        mlMarkers: [],
        opts: opts,
        userInteracted: false,
        lastLocatedSig: '',
        centerOnDevice: targetLoc => {
          const loc = isValidCoord(targetLoc) ? targetLoc : ctrl.opts.primary;
          if (!isValidCoord(loc)) return;
          const acc = Number(loc.accuracyMeters || (loc.isApproximate ? 180 : 25));
          zoom = Math.max(zoom, acc >= 600 ? 13.2 : (acc >= 180 ? 14.5 : 15.6));
          centerLat = Number(loc.latitude);
          centerLon = Number(loc.longitude);
          if (ctrl.mlMap && ctrl.mlReady) {
            ctrl.mlMap.flyTo({ center: [centerLon, centerLat], zoom: zoom, essential: true });
          } else {
            drawCanvasFallback();
          }
        },
        update: nextOpts => {
          ctrl.opts = nextOpts;
          renderTopBadges();
          const markers = effectiveMarkers(nextOpts);
          const sig = markers.map(m => m.deviceId).join('|');
          if (!ctrl.userInteracted && sig !== ctrl.lastLocatedSig) {
            ctrl.lastLocatedSig = sig;
            fitViewportToMarkers(markers, nextOpts.primary);
          }
          drawCanvasFallback();
          if (ctrl.mlMap && ctrl.mlReady) {
            syncMapLibreOverlays();
          }
        }
      };

      function effectiveMarkers(o) {
        if (Array.isArray(o.markers) && o.markers.length > 0) {
          return o.markers.filter(m => m && isValidCoord(m.location));
        }
        return [{
          deviceId: 'primary',
          displayName: o.label || 'Protected device',
          role: 'protected_device',
          isCurrentRequester: false,
          isSelected: true,
          isAlarming: Boolean(o.isAlarming),
          location: o.primary
        }];
      }

      function fitViewportToMarkers(markers, fallbackPrimary) {
        if (markers.length >= 2) {
          let minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
          markers.forEach(m => {
            const la = Number(m.location.latitude);
            const lo = Number(m.location.longitude);
            if (la < minLat) minLat = la;
            if (la > maxLat) maxLat = la;
            if (lo < minLon) minLon = lo;
            if (lo > maxLon) maxLon = lo;
          });
          centerLat = (minLat + maxLat) / 2;
          centerLon = (minLon + maxLon) / 2;
          const spanMeters = haversineMeters(
            { latitude: minLat, longitude: minLon },
            { latitude: maxLat, longitude: maxLon }
          );
          if (spanMeters < 60) zoom = 16.0;
          else if (spanMeters < 350) zoom = 15.0;
          else if (spanMeters < 1500) zoom = 13.6;
          else if (spanMeters < 8000) zoom = 11.8;
          else zoom = 9.8;
          if (ctrl.mlMap && ctrl.mlReady && spanMeters >= 60) {
            try {
              ctrl.mlMap.fitBounds([[minLon, minLat], [maxLon, maxLat]], {
                padding: { top: 54, bottom: 54, left: 48, right: 56 },
                maxZoom: 16,
                duration: 450
              });
              return;
            } catch (_) {}
          }
        } else if (isValidCoord(fallbackPrimary)) {
          centerLat = Number(fallbackPrimary.latitude);
          centerLon = Number(fallbackPrimary.longitude);
        }
        if (ctrl.mlMap && ctrl.mlReady) {
          ctrl.mlMap.jumpTo({ center: [centerLon, centerLat], zoom: zoom });
        }
      }

      function renderTopBadges() {
        const o = ctrl.opts;
        let html = '';
        if (o.badge) {
          html += '<span class="pill ' + o.badge.cls + '">' + escapeHtml(o.badge.label) + '</span>';
        }
        if (o.secondaryBadge) {
          html += '<span class="pill pill-map-light">' + escapeHtml(o.secondaryBadge) + '</span>';
        }
        if (o.alarmOrigin && differsMeaningfully(o.primary, o.alarmOrigin)) {
          html += '<span class="pill pill-warn">Start → Latest</span>';
        }
        overlayTop.innerHTML = html;
      }

      function drawCanvasFallback() {
        const o = ctrl.opts;
        const rect = stageEl.getBoundingClientRect();
        const w = Math.max(240, rect.width || 340);
        const h = Math.max(200, rect.height || 292);
        const dpr = window.devicePixelRatio || 1;
        canvas.width = Math.round(w * dpr);
        canvas.height = Math.round(h * dpr);
        const ctx = canvas.getContext('2d');
        if (!ctx) return;
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

        // Crisp light street-map fallback styling
        ctx.fillStyle = '#EEF2F6';
        ctx.fillRect(0, 0, w, h);

        const worldSize = 256 * Math.pow(2, zoom);
        const cw = mercatorProject(centerLat, centerLon, worldSize);
        const step = 48;
        const sx = -((cw.x % step) + step) % step;
        const sy = -((cw.y % step) + step) % step;

        // Subtle park blocks for spatial orientation
        ctx.fillStyle = '#E2F1E8';
        ctx.fillRect(sx + step * 0.15, sy + step * 0.15, step * 1.7, step * 1.2);
        ctx.fillRect(w - step * 2.2, h - step * 1.8, step * 1.5, step * 1.1);

        for (let x = sx, i = 0; x < w + step; x += step, i++) {
          ctx.strokeStyle = i % 3 === 0 ? '#CBD5E1' : '#FFFFFF';
          ctx.lineWidth = i % 3 === 0 ? 4.5 : 2.5;
          ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, h); ctx.stroke();
        }
        for (let y = sy, i = 0; y < h + step; y += step, i++) {
          ctx.strokeStyle = i % 3 === 0 ? '#CBD5E1' : '#FFFFFF';
          ctx.lineWidth = i % 3 === 0 ? 4.5 : 2.5;
          ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
        }

        const toScr = loc => {
          const p = mercatorProject(loc.latitude, loc.longitude, worldSize);
          return { x: w / 2 + (p.x - cw.x), y: h / 2 + (p.y - cw.y) };
        };

        const trail = Array.isArray(o.trail) ? o.trail.filter(isValidCoord) : [];
        if (trail.length >= 2) {
          ctx.strokeStyle = '#D97706';
          ctx.lineWidth = 3.5;
          ctx.beginPath();
          trail.forEach((pt, idx) => {
            const sp = toScr(pt);
            if (idx === 0) ctx.moveTo(sp.x, sp.y); else ctx.lineTo(sp.x, sp.y);
          });
          ctx.stroke();
        }

        if (o.alarmOrigin && isValidCoord(o.alarmOrigin) && differsMeaningfully(o.primary, o.alarmOrigin)) {
          const ap = toScr(o.alarmOrigin);
          ctx.fillStyle = '#D97706';
          ctx.beginPath(); ctx.arc(ap.x, ap.y, 6.5, 0, Math.PI * 2); ctx.fill();
          ctx.strokeStyle = '#FFFFFF'; ctx.lineWidth = 2; ctx.stroke();
        }

        const markers = effectiveMarkers(o);
        const offsets = computeMarkerPixelOffsets(markers);
        const mpp = (156543.03 * Math.cos(centerLat * Math.PI / 180)) / Math.pow(2, zoom);

        markers.forEach((m, idx) => {
          const base = toScr(m.location);
          const off = offsets[idx];
          const px = base.x + off.x;
          const py = base.y + off.y;
          const mAcc = Number(m.location.accuracyMeters || 30);
          if (m.isSelected) {
            const rPx = Math.max(18, Math.min(88, mAcc / Math.max(0.05, mpp)));
            ctx.fillStyle = m.isAlarming ? 'rgba(214,69,58,0.14)' : (m.role === 'protected_device' ? 'rgba(46,155,104,0.15)' : 'rgba(37,99,235,0.14)');
            ctx.beginPath(); ctx.arc(base.x, base.y, rPx, 0, Math.PI * 2); ctx.fill();
            ctx.strokeStyle = m.isAlarming ? 'rgba(214,69,58,0.55)' : (m.role === 'protected_device' ? 'rgba(46,155,104,0.55)' : 'rgba(37,99,235,0.5)');
            ctx.lineWidth = 1.5; ctx.stroke();
          }
          if (off.coLocated) {
            ctx.strokeStyle = 'rgba(15,23,42,0.35)';
            ctx.lineWidth = 1.5;
            ctx.beginPath(); ctx.moveTo(base.x, base.y); ctx.lineTo(px, py); ctx.stroke();
            ctx.fillStyle = '#334155';
            ctx.beginPath(); ctx.arc(base.x, base.y, 3, 0, Math.PI * 2); ctx.fill();
          }
          const pinColor = m.isAlarming ? '#D6453A' : (m.role === 'protected_device' ? '#1E8254' : '#2563EB');
          if (m.isSelected) {
            ctx.fillStyle = 'rgba(229,142,38,0.38)';
            ctx.beginPath(); ctx.arc(px, py, 19, 0, Math.PI * 2); ctx.fill();
          }
          ctx.fillStyle = '#FFFFFF';
          ctx.beginPath(); ctx.arc(px, py, 15, 0, Math.PI * 2); ctx.fill();
          ctx.fillStyle = pinColor;
          ctx.beginPath(); ctx.arc(px, py, 12.5, 0, Math.PI * 2); ctx.fill();

          // Distinct simplified laptop vs phone glyph inside fallback pin
          ctx.strokeStyle = '#FFFFFF';
          ctx.lineWidth = 1.8;
          if (m.role === 'protected_device') {
            ctx.strokeRect(px - 5.5, py - 4.5, 11, 7);
            ctx.beginPath(); ctx.moveTo(px - 7.5, py + 4.5); ctx.lineTo(px + 7.5, py + 4.5); ctx.stroke();
          } else {
            ctx.strokeRect(px - 4, py - 6, 8, 12);
          }

          const lbl = m.isCurrentRequester ? (m.displayName + ' · This phone') : m.displayName;
          ctx.font = '700 11px -apple-system, BlinkMacSystemFont, sans-serif';
          const tw = Math.min(144, ctx.measureText(lbl).width + 12);
          const lx = px - tw / 2;
          const ly = off.labelAbove ? (py - 35) : (py + 17);
          ctx.fillStyle = 'rgba(255,255,255,0.95)';
          ctx.fillRect(lx, ly, tw, 18);
          ctx.strokeStyle = 'rgba(15,23,42,0.18)';
          ctx.lineWidth = 1;
          ctx.strokeRect(lx, ly, tw, 18);
          ctx.fillStyle = '#0F172A';
          ctx.textAlign = 'center';
          ctx.textBaseline = 'middle';
          ctx.fillText(lbl.length > 21 ? (lbl.slice(0, 20) + '…') : lbl, px, ly + 9.5);
        });
        ctrl.lastCanvasHitTargets = markers.map((m, idx) => {
          const base = toScr(m.location);
          return {
            deviceId: m.deviceId,
            x: base.x + offsets[idx].x,
            y: base.y + offsets[idx].y
          };
        });
      }

      function syncMapLibreOverlays() {
        const ml = ctrl.mlMap;
        if (!ml || !ctrl.mlReady) return;
        const o = ctrl.opts;
        ctrl.mlMarkers.forEach(m => { try { m.remove(); } catch (_) {} });
        ctrl.mlMarkers = [];

        const trail = Array.isArray(o.trail) ? o.trail.filter(isValidCoord) : [];
        const trailGeo = {
          type: 'Feature',
          geometry: {
            type: 'LineString',
            coordinates: trail.map(p => [Number(p.longitude), Number(p.latitude)])
          }
        };
        if (ml.getSource('incident-trail')) {
          ml.getSource('incident-trail').setData(trailGeo);
        } else if (trail.length >= 2) {
          ml.addSource('incident-trail', { type: 'geojson', data: trailGeo });
          ml.addLayer({
            id: 'incident-trail-line',
            type: 'line',
            source: 'incident-trail',
            paint: { 'line-color': '#D97706', 'line-width': 3.5 }
          });
        }

        if (o.alarmOrigin && isValidCoord(o.alarmOrigin) && differsMeaningfully(o.primary, o.alarmOrigin)) {
          const originEl = document.createElement('div');
          originEl.style.cssText = 'width:13px;height:13px;border-radius:50%;background:#D97706;border:2px solid #FFFFFF;box-shadow:0 2px 6px rgba(15,23,42,0.25);';
          const om = new window.maplibregl.Marker({ element: originEl })
            .setLngLat([Number(o.alarmOrigin.longitude), Number(o.alarmOrigin.latitude)])
            .addTo(ml);
          ctrl.mlMarkers.push(om);
        }

        const markers = effectiveMarkers(o);
        const offsets = computeMarkerPixelOffsets(markers);
        markers.forEach((m, idx) => {
          const off = offsets[idx];
          const pinColor = m.isAlarming ? '#D6453A' : (m.role === 'protected_device' ? '#1E8254' : '#2563EB');
          const lblText = m.isCurrentRequester ? (m.displayName + ' · This phone') : m.displayName;
          const wrap = document.createElement('div');
          wrap.className = 'map-pin-wrap' + (m.isSelected ? ' selected' : '');
          wrap.setAttribute('data-device-id', m.deviceId);
          const badgeHtml =
            '<div class="map-pin-badge" style="background:' + pinColor + ';">' +
            deviceSvgIcon(m.role, 16) +
            '</div>';
          const labelHtml = off.labelAbove
            ? '<div class="map-pin-label" style="margin-top:0;margin-bottom:4px;">' + escapeHtml(lblText) + '</div>'
            : '<div class="map-pin-label">' + escapeHtml(lblText) + '</div>';
          wrap.innerHTML = off.labelAbove ? (labelHtml + badgeHtml) : (badgeHtml + labelHtml);
          wrap.onclick = ev => {
            ev.stopPropagation();
            if (typeof o.onSelectDevice === 'function') {
              o.onSelectDevice(m.deviceId);
            }
          };
          const marker = new window.maplibregl.Marker({
            element: wrap,
            offset: [off.x, off.y]
          })
            .setLngLat([Number(m.location.longitude), Number(m.location.latitude)])
            .addTo(ml);
          ctrl.mlMarkers.push(marker);
        });
      }

      renderTopBadges();
      const initMarkers = effectiveMarkers(opts);
      ctrl.lastLocatedSig = initMarkers.map(m => m.deviceId).join('|');
      fitViewportToMarkers(initMarkers, opts.primary);
      drawCanvasFallback();

      let dragLast = null;
      let dragMoved = false;
      stageEl.onpointerdown = e => {
        if (e.target && (e.target.closest('.map-ctrl-btn') || e.target.closest('.map-pin-wrap'))) return;
        dragLast = { x: e.clientX, y: e.clientY };
        dragMoved = false;
      };
      stageEl.onpointermove = e => {
        if (!dragLast || (ctrl.mlMap && ctrl.mlReady)) return;
        const dx = e.clientX - dragLast.x;
        const dy = e.clientY - dragLast.y;
        if (Math.abs(dx) > 2 || Math.abs(dy) > 2) {
          dragMoved = true;
          ctrl.userInteracted = true;
        }
        dragLast = { x: e.clientX, y: e.clientY };
        const worldSize = 256 * Math.pow(2, zoom);
        const cw = mercatorProject(centerLat, centerLon, worldSize);
        const next = mercatorUnproject(cw.x - dx, Math.max(0, Math.min(worldSize, cw.y - dy)), worldSize);
        centerLat = next.lat;
        centerLon = next.lon;
        drawCanvasFallback();
      };
      stageEl.onpointerup = e => {
        if (dragLast && !dragMoved && !(ctrl.mlMap && ctrl.mlReady) && Array.isArray(ctrl.lastCanvasHitTargets)) {
          const rect = stageEl.getBoundingClientRect();
          const cx = e.clientX - rect.left;
          const cy = e.clientY - rect.top;
          const hit = ctrl.lastCanvasHitTargets.find(t => Math.hypot(t.x - cx, t.y - cy) <= 24);
          if (hit && typeof ctrl.opts.onSelectDevice === 'function') {
            ctrl.opts.onSelectDevice(hit.deviceId);
          }
        }
        dragLast = null;
      };
      stageEl.onpointercancel = () => { dragLast = null; };

      stageEl.querySelector('[data-act="in"]').onclick = () => {
        ctrl.userInteracted = true;
        zoom = Math.min(18, (ctrl.mlMap && ctrl.mlReady ? ctrl.mlMap.getZoom() : zoom) + 1);
        if (ctrl.mlMap && ctrl.mlReady) ctrl.mlMap.zoomTo(zoom); else drawCanvasFallback();
      };
      stageEl.querySelector('[data-act="out"]').onclick = () => {
        ctrl.userInteracted = true;
        zoom = Math.max(3, (ctrl.mlMap && ctrl.mlReady ? ctrl.mlMap.getZoom() : zoom) - 1);
        if (ctrl.mlMap && ctrl.mlReady) ctrl.mlMap.zoomTo(zoom); else drawCanvasFallback();
      };

      if (window.maplibregl && navigator.onLine !== false) {
        try {
          const ml = new window.maplibregl.Map({
            container: vectorHost,
            style: 'https://tiles.openfreemap.org/styles/liberty',
            center: [centerLon, centerLat],
            zoom: zoom,
            attributionControl: false
          });
          ctrl.mlMap = ml;
          ml.on('dragstart', () => { ctrl.userInteracted = true; });
          ml.on('zoomstart', e => {
            if (e && e.originalEvent) ctrl.userInteracted = true;
          });
          ml.on('load', () => {
            ctrl.mlReady = true;
            const curMarkers = effectiveMarkers(ctrl.opts);
            if (!ctrl.userInteracted && curMarkers.length >= 2) {
              fitViewportToMarkers(curMarkers, ctrl.opts.primary);
            }
            syncMapLibreOverlays();
          });
          ml.on('error', () => {
            if (!ctrl.mlReady) {
              try { ml.remove(); } catch (_) {}
              ctrl.mlMap = null;
            }
          });
        } catch (_) {}
      }

      mapControllers[mapKey] = ctrl;
      return ctrl;
    }

    async function fetchAuthorizedDevicesLocations(showFeedback) {
      if (!state.companionToken) return;
      try {
        const res = await fetch('/v1/devices/locations', {
          headers: { 'Authorization': 'Bearer ' + state.companionToken },
          cache: 'no-store'
        });
        if (await isAuthenticUnauthorizedSession(res)) {
          await handleServerRevokedSession();
          return;
        }
        if (isAuthenticWatSafeHeader(res) && res.ok) {
          const data = await res.json();
          if (Array.isArray(data.devices)) {
            state.authorizedDevices = data.devices;
            saveState();
          }
          if (showFeedback) showInfo('Device locations refreshed.');
          renderDevicesTab();
        }
      } catch (_) {
        if (showFeedback) showError('Service temporarily unavailable — showing last saved device info.');
      }
    }

    function buildEffectiveDevicesRoster() {
      let base;
      if (Array.isArray(state.authorizedDevices) && state.authorizedDevices.length > 0) {
        base = state.authorizedDevices.map(d => Object.assign({}, d));
      } else {
        const evWithLoc = state.events.find(e => isValidCoord(e.location));
        const hostOnline = connState !== 'laptop_offline';
        base = [
          {
            deviceId: 'host_primary',
            displayName: state.hostDisplayName || 'Protected Laptop',
            role: 'protected_device',
            platform: 'Protected laptop',
            online: hostOnline,
            protectionStatusLabel: formatProtectionLabel(state.hostProtectionState),
            isAlarming: String(state.hostProtectionState || '').toLowerCase() === 'triggered',
            trackingState: evWithLoc ? (evWithLoc.locationTrackingState || 'last_known') : 'unavailable',
            latestLocation: evWithLoc ? evWithLoc.location : null,
            alarmLocation: evWithLoc ? (evWithLoc.alarmLocation || evWithLoc.location) : null,
            locationTrail: evWithLoc && Array.isArray(evWithLoc.locationTrail) ? evWithLoc.locationTrail : [],
            locationStatus: evWithLoc ? 'attached' : 'notRequested',
            statusExplanation: hostOnline
              ? 'Arm protection or allow Location access on your laptop to report its position.'
              : 'Laptop is currently offline or sleeping. New coordinates arrive when it reconnects.'
          },
          {
            deviceId: state.deviceId || 'phone_self',
            displayName: state.phoneDisplayName || 'This Phone',
            role: 'companion_phone',
            platform: detectPlatformLabel(),
            online: true,
            isCurrentRequester: true,
            locationSharingEnabled: Boolean(state.phoneLocationSharingEnabled),
            protectionStatusLabel: 'Companion · Alerts on',
            isAlarming: false,
            trackingState: 'unavailable',
            latestLocation: null,
            locationStatus: 'notRequested',
            statusExplanation: 'Location not shared. Tap "Share this phone’s location" to show this phone alongside your laptop while WATSafe is open.'
          }
        ];
      }
      if (state.phoneLocationSharingEnabled && isValidCoord(state.phoneLatestLocation)) {
        base = base.map(d => {
          if (d.isCurrentRequester || (state.deviceId && d.deviceId === state.deviceId)) {
            return Object.assign({}, d, {
              isCurrentRequester: true,
              locationSharingEnabled: true,
              latestLocation: isValidCoord(d.latestLocation) ? d.latestLocation : state.phoneLatestLocation,
              trackingState: document.visibilityState === 'visible' ? 'live' : 'last_known',
              locationStatus: 'attached'
            });
          }
          return d;
        });
      }
      return base;
    }

    function protectionBadgeClass(dev) {
      if (dev.isAlarming) return 'pill-alert';
      const lbl = String(dev.protectionStatusLabel || '').toLowerCase();
      if (lbl.indexOf('interrupted') >= 0) return 'pill-alert';
      if (lbl.indexOf('protected') >= 0 || lbl.indexOf('alerts on') >= 0) return 'pill-ok';
      if (lbl.indexOf('arming') >= 0 || lbl.indexOf('paused') >= 0 || lbl.indexOf('setup') >= 0) return 'pill-warn';
      return 'pill-neutral';
    }

    function eventKindMeta(ev) {
      if (ev && ev.isTest) return { label: 'Test alert', cls: 'pill-warn' };
      const kind = String((ev && ev.kind) || '').trim();
      if (kind === 'protectionInterrupted') return { label: 'Protection interrupted', cls: 'pill-alert' };
      if (kind === 'detectorFailureDuringMonitoring') return { label: 'Monitoring stopped', cls: 'pill-warn' };
      return { label: 'Alarm triggered', cls: 'pill-alert' };
    }

    function renderDevicesTab() {
      if (!els.tabDevices || els.tabDevices.classList.contains('hidden')) return;
      const devices = buildEffectiveDevicesRoster();
      let selected = devices.find(d => d.deviceId === selectedDeviceId) ||
        devices.find(d => d.role === 'protected_device') ||
        devices[0];
      if (!selected) return;
      selectedDeviceId = selected.deviceId;

      // 1. Single horizontal device selector strip (>= 44px touch targets, zero duplicate cards)
      els.devicesRosterList.innerHTML = '';
      devices.forEach(dev => {
        const chip = document.createElement('button');
        chip.type = 'button';
        chip.setAttribute('role', 'tab');
        chip.setAttribute('aria-selected', dev.deviceId === selected.deviceId ? 'true' : 'false');
        chip.className = 'device-chip' + (dev.deviceId === selected.deviceId ? ' selected' : '');
        const dotColor = dev.isAlarming ? '#D6453A' : (dev.online ? '#2E9B68' : '#E58E26');
        const chipTitle = dev.isCurrentRequester ? (dev.displayName + ' · This phone') : dev.displayName;
        chip.innerHTML =
          deviceSvgIcon(dev.role, 16) +
          '<span>' + escapeHtml(chipTitle) + '</span>' +
          '<span class="chip-dot" style="background:' + dotColor + ';"></span>';
        chip.onclick = () => {
          selectedDeviceId = dev.deviceId;
          renderDevicesTab();
          if (isValidCoord(dev.latestLocation) && mapControllers.devices) {
            mapControllers.devices.centerOnDevice(dev.latestLocation);
          }
        };
        els.devicesRosterList.appendChild(chip);
      });

      // 2. Multi-device interactive light map (keeps located devices visible even if an unlocated chip is selected)
      const locatedDevices = devices.filter(d => isValidCoord(d.latestLocation));
      const selectedHasCoord = isValidCoord(selected.latestLocation);
      if (locatedDevices.length > 0) {
        const mapPrimaryDev = selectedHasCoord ? selected : locatedDevices[0];
        const badge = trackingBadgeMeta(mapPrimaryDev.trackingState);
        const secondaryBadge = !selectedHasCoord
          ? ((selected.isCurrentRequester ? 'This phone' : selected.displayName) + ' · location not shared')
          : (locatedDevices.length >= 2 ? (locatedDevices.length + ' devices on map') : '');
        mountInteractiveMap(els.devicesMapStage, 'devices', {
          primary: mapPrimaryDev.latestLocation,
          label: mapPrimaryDev.displayName,
          alarmOrigin: selectedHasCoord ? selected.alarmLocation : mapPrimaryDev.alarmLocation,
          trail: selectedHasCoord ? selected.locationTrail : mapPrimaryDev.locationTrail,
          badge: badge,
          secondaryBadge: secondaryBadge,
          isAlarming: Boolean(mapPrimaryDev.isAlarming),
          markers: locatedDevices.map(d => ({
            deviceId: d.deviceId,
            displayName: d.displayName,
            role: d.role,
            isCurrentRequester: Boolean(d.isCurrentRequester),
            isSelected: d.deviceId === selected.deviceId,
            isAlarming: Boolean(d.isAlarming),
            location: d.latestLocation
          })),
          onSelectDevice: id => {
            selectedDeviceId = id;
            renderDevicesTab();
          }
        });
      } else {
        destroyMapController('devices');
        els.devicesMapStage.innerHTML =
          '<div style="height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px;text-align:center;color:#0F172A;">' +
          '<div style="font-weight:800;font-size:16px;margin-bottom:6px;">Location unavailable</div>' +
          '<div style="font-size:13.5px;color:#475569;max-width:300px;line-height:1.45;">' +
          escapeHtml(selected.statusExplanation || 'Allow Location access on your protected laptop or share this phone’s location while WATSafe is open.') +
          '</div></div>';
      }

      // 3. Single concise selected-device detail card
      const connPill = '<span class="pill ' + (selected.online ? 'pill-ok' : 'pill-warn') + '">' +
        (selected.online ? 'Online' : 'Offline') + '</span>';
      const protPill = '<span class="pill ' + protectionBadgeClass(selected) + '">' +
        escapeHtml(selected.protectionStatusLabel || (selected.role === 'protected_device' ? 'Protection off' : 'Companion')) + '</span>';
      const thisPhoneTag = selected.isCurrentRequester
        ? ' <span class="pill pill-neutral" style="font-size:11px;padding:2px 8px;">This phone</span>'
        : '';

      if (selectedHasCoord) {
        const loc = selected.latestLocation;
        const isLastKnown = selected.trackingState !== 'live' || Boolean(loc.isLastKnown);
        const placeText = getReadableLocationSummary(loc);
        const mapsHref = 'https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent(loc.latitude + ',' + loc.longitude);
        const stopBtnHtml = selected.isCurrentRequester && state.phoneLocationSharingEnabled
          ? '<button type="button" id="stopPhoneLocInlineBtn" class="btn btn-secondary" style="margin-top:8px;font-size:13.5px;">Stop sharing phone location</button>'
          : '';
        els.selectedDeviceCard.innerHTML =
          '<div style="display:flex;justify-content:space-between;align-items:flex-start;gap:8px;flex-wrap:wrap;">' +
          '<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">' +
          '<span style="color:var(--muted);display:inline-flex;">' + deviceSvgIcon(selected.role, 18) + '</span>' +
          '<h2 style="margin:0;">' + escapeHtml(selected.displayName) + '</h2>' + thisPhoneTag +
          '</div>' +
          '<span class="pill pill-neutral">' + escapeHtml(formatAccuracyLabel(loc)) + '</span>' +
          '</div>' +
          '<div style="display:flex;gap:6px;flex-wrap:wrap;margin-top:9px;">' + connPill + protPill + '</div>' +
          '<div style="margin-top:12px;font-size:15px;font-weight:700;color:var(--text);">' + escapeHtml(placeText) + '</div>' +
          '<div style="font-size:13px;color:var(--muted);margin-top:3px;">' +
          escapeHtml(formatRelativeAge(loc.capturedAtUtc, isLastKnown)) +
          '</div>' +
          '<div class="btn-row">' +
          '<button type="button" id="centerSelectedDeviceBtn" class="btn btn-secondary">Center on device</button>' +
          '<a class="btn btn-primary" target="_blank" rel="noopener" href="' + mapsHref + '">Open in Maps</a>' +
          '</div>' +
          stopBtnHtml +
          '<details class="coords-disclosure">' +
          '<summary>Coordinates</summary>' +
          '<div class="coords-mono">' + Number(loc.latitude).toFixed(5) + ', ' + Number(loc.longitude).toFixed(5) + '</div>' +
          '<div style="margin-top:3px;font-size:12px;color:var(--subtle);">Captured ' + escapeHtml(formatTime(loc.capturedAtUtc)) + '</div>' +
          '</details>';
        const centerBtn = document.getElementById('centerSelectedDeviceBtn');
        if (centerBtn) {
          centerBtn.onclick = () => {
            if (mapControllers.devices) mapControllers.devices.centerOnDevice(loc);
          };
        }
        const stopInlineBtn = document.getElementById('stopPhoneLocInlineBtn');
        if (stopInlineBtn) {
          stopInlineBtn.onclick = () => disableCompanionPhoneLocationSharing(true);
        }
      } else {
        const isCurrentPhone = Boolean(selected.isCurrentRequester);
        const denied = selected.locationStatus === 'permissionDenied' || (isCurrentPhone && state.phoneLocationPermission === 'denied');
        let actionHtml = '';
        if (isCurrentPhone) {
          if (denied) {
            actionHtml =
              '<div class="guide-box" style="margin:10px 0 0;">' +
              '<strong>Location permission turned off</strong>' +
              '<p style="margin:5px 0 0;font-size:13px;">Open iOS <strong>Settings → Privacy &amp; Security → Location Services → Safari Websites</strong>, allow access while using the app, then tap below.</p>' +
              '</div>' +
              '<button type="button" id="shareThisPhoneLocationBtn" class="btn btn-secondary">Retry sharing phone location</button>';
          } else {
            actionHtml =
              '<button type="button" id="shareThisPhoneLocationBtn" class="btn btn-primary" style="margin-top:12px;">Share this phone’s location</button>' +
              '<p style="margin:8px 0 0;font-size:12px;color:var(--subtle);">Updates only while WATSafe is open on screen.</p>';
          }
        }
        els.selectedDeviceCard.innerHTML =
          '<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">' +
          '<span style="color:var(--muted);display:inline-flex;">' + deviceSvgIcon(selected.role, 18) + '</span>' +
          '<h2 style="margin:0;">' + escapeHtml(selected.displayName) + '</h2>' + thisPhoneTag +
          '</div>' +
          '<div style="display:flex;gap:6px;flex-wrap:wrap;margin-top:9px;">' + connPill + protPill + '</div>' +
          '<div style="margin-top:12px;font-size:14px;font-weight:700;color:var(--text);">' +
          (denied ? 'Location permission turned off' : (isCurrentPhone ? 'Location not shared' : 'Location unavailable')) +
          '</div>' +
          '<p style="margin:4px 0 0;font-size:13.5px;">' +
          escapeHtml(selected.statusExplanation || 'No valid position has been reported for this device yet.') +
          '</p>' +
          actionHtml;
        const shareBtn = document.getElementById('shareThisPhoneLocationBtn');
        if (shareBtn) {
          shareBtn.onclick = () => enableCompanionPhoneLocationSharing(true);
        }
      }
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
          const kindMeta = eventKindMeta(ev);
          let locHtml = '<div class="guide-box"><strong>Location unavailable</strong><p style="margin:6px 0 0 0;font-size:13.5px;">Location permission was turned off or unavailable on the protected device when this event was recorded.</p></div>';
          if (ev.locationStatus === 'pending' && !isValidCoord(ev.location)) {
            locHtml = '<div class="guide-box" style="border-color:var(--amber);"><strong>Getting device location…</strong><p style="margin:6px 0 0 0;font-size:13.5px;">Waiting for your protected laptop to report coordinates. This view updates automatically.</p></div>';
          } else if (ev.locationStatus === 'notRequested' && !isValidCoord(ev.location)) {
            locHtml = '<div class="guide-box"><strong>Location unavailable</strong><p style="margin:6px 0 0 0;font-size:13.5px;">Location sharing on alarm was turned off in Settings on the protected device.</p></div>';
          } else if (isValidCoord(ev.location)) {
            const loc = ev.location;
            const alarmOrigin = isValidCoord(ev.alarmLocation) ? ev.alarmLocation : loc;
            const hasDistinct = differsMeaningfully(loc, alarmOrigin);
            const trail = Array.isArray(ev.locationTrail) ? ev.locationTrail.filter(isValidCoord) : [];
            const mapsHref = 'https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent(loc.latitude + ',' + loc.longitude);
            const comparisonHtml = hasDistinct
              ? ('<div class="guide-box" style="margin:10px 0;">' +
                 '<div style="font-size:12.5px;color:var(--muted);">Alarm-time location: <strong style="color:var(--text);">' + Number(alarmOrigin.latitude).toFixed(5) + ', ' + Number(alarmOrigin.longitude).toFixed(5) + '</strong> (' + escapeHtml(formatTime(alarmOrigin.capturedAtUtc)) + ')</div>' +
                 '<div style="font-size:12.5px;color:var(--muted);margin-top:6px;">Latest known location: <strong style="color:var(--text);">' + Number(loc.latitude).toFixed(5) + ', ' + Number(loc.longitude).toFixed(5) + '</strong> · ' + escapeHtml(formatAccuracyLabel(loc)) + '</div>' +
                 '</div>')
              : ('<div style="font-size:14px;font-weight:700;margin-top:10px;">' + escapeHtml(getReadableLocationSummary(loc)) + ' · ' + escapeHtml(formatAccuracyLabel(loc)) + '</div>');
            const trailNote = trail.length >= 2
              ? ('<div style="font-size:12.5px;color:var(--amber);font-weight:700;margin-top:4px;">' + trail.length + ' verified movement updates recorded</div>')
              : '';
            locHtml = '<div style="margin-top:12px;">' +
              '<div id="incidentMapStage" class="map-stage" style="height:240px;"></div>' +
              comparisonHtml +
              trailNote +
              '<div style="font-size:12.5px;color:var(--muted);margin-top:4px;">' + escapeHtml(formatRelativeAge(loc.capturedAtUtc, ev.locationTrackingState !== 'live')) + ' (' + escapeHtml(formatTime(loc.capturedAtUtc)) + ')</div>' +
              '<div class="btn-row">' +
              '<button type="button" id="incidentCenterBtn" class="btn btn-secondary">Center on device</button>' +
              '<a class="btn btn-primary" target="_blank" rel="noopener" href="' + mapsHref + '">Open in Maps</a>' +
              '</div>' +
              '<details class="coords-disclosure"><summary>Coordinates</summary><div class="coords-mono">' + Number(loc.latitude).toFixed(5) + ', ' + Number(loc.longitude).toFixed(5) + '</div></details>' +
              '</div>';
          }
          const receiptBadge = ev.receiptConfirmed
            ? '<span class="pill pill-ok" style="margin-left:8px;">Phone receipt confirmed</span>'
            : '<span class="pill pill-warn" style="margin-left:8px;">Awaiting phone push receipt</span>';
          els.eventDetailCard.innerHTML =
            '<div style="display:flex;flex-wrap:wrap;gap:6px;align-items:center;">' +
            '<span class="pill ' + kindMeta.cls + '">' + escapeHtml(kindMeta.label) + '</span>' +
            receiptBadge +
            '</div>' +
            '<h2 style="margin-top:10px;">' + escapeHtml(ev.hostDisplayName || state.hostDisplayName) + '</h2>' +
            '<p style="margin-bottom:6px;">' + escapeHtml(formatTime(ev.triggeredAtUtc)) + '</p>' +
            '<p style="margin-bottom:8px;">' + escapeHtml(ev.triggerSummary || kindMeta.label) + '</p>' + locHtml;
          els.eventDetailCard.classList.remove('hidden');

          if (isValidCoord(ev.location) && !els.tabActivity.classList.contains('hidden')) {
            const stage = document.getElementById('incidentMapStage');
            const badge = trackingBadgeMeta(ev.locationTrackingState);
            const ctrl = mountInteractiveMap(stage, 'incident', {
              primary: ev.location,
              label: ev.hostDisplayName || state.hostDisplayName,
              alarmOrigin: isValidCoord(ev.alarmLocation) ? ev.alarmLocation : ev.location,
              trail: Array.isArray(ev.locationTrail) ? ev.locationTrail : [],
              badge: badge,
              isAlarming: !ev.isTest
            });
            const centerBtn = document.getElementById('incidentCenterBtn');
            if (centerBtn && ctrl) {
              centerBtn.onclick = () => ctrl.centerOnDevice(ev.location);
            }
          }
        }
      } else {
        els.eventDetailCard.classList.add('hidden');
      }

      state.events.forEach(ev => {
        const div = document.createElement('div');
        div.className = 'event-item' + (ev.incidentId === selectedIncidentId ? ' selected' : '');
        const hasLoc = isValidCoord(ev.location);
        const kindMeta = eventKindMeta(ev);
        div.innerHTML =
          '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px;gap:8px;">' +
          '<strong>' + escapeHtml(kindMeta.label) + ' · ' + escapeHtml(ev.hostDisplayName || state.hostDisplayName) + '</strong>' +
          '<span style="font-size:12px;color:var(--muted);">' + escapeHtml(formatTime(ev.triggeredAtUtc)) + '</span>' +
          '</div>' +
          '<div style="font-size:13.5px;color:var(--muted);">' + escapeHtml(ev.triggerSummary || '') + '</div>' +
          (hasLoc
            ? '<div style="margin-top:8px;color:var(--amber);font-size:13px;font-weight:700;">View map &amp; location →</div>'
            : '<div style="margin-top:6px;color:var(--subtle);font-size:12px;">' + escapeHtml(ev.locationStatus === 'pending' ? 'Getting device location…' : 'Location unavailable') + '</div>');
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
          if (!item.receiptConfirmed) {
            acknowledgeEventReceipt(item.incidentId, 'companion_poll');
          }
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
      const kindMeta = eventKindMeta(ev);
      const body = kindMeta.label + ' — tap to view in Activity';
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
        if (data.deviceId) state.deviceId = data.deviceId;
        if (typeof data.backendPushRegistered === 'boolean') {
          state.backendPushRegistered = data.backendPushRegistered;
        }
        if (data.companionLocation && isValidCoord(data.companionLocation)) {
          state.phoneLatestLocation = data.companionLocation;
        }
        const prevNeedsRenewal = state.pushSubscriptionNeedsRenewal;
        state.pushSubscriptionNeedsRenewal = Boolean(data.pushSubscriptionNeedsRenewal);
        state.lastPushErrorCode = data.lastPushErrorCode || null;
        if (state.pushSubscriptionNeedsRenewal && !prevNeedsRenewal && activePushSubscription) {
          syncCompanionReadinessToBackend();
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
          // Only auto-acknowledge via foreground poll when no background push test is waiting on push_sw receipt
          if (!item.receiptConfirmed && item.incidentId !== pendingTestIncidentId) {
            acknowledgeEventReceipt(item.incidentId, 'companion_poll');
          } else if (item.receiptConfirmed && pendingTestIncidentId && item.incidentId === pendingTestIncidentId) {
            pendingTestIncidentId = null;
            showInfo('Phone receipt confirmed — test notification arrived on this phone.');
          }
        }
        if ((data.latestSeq || 0) > state.lastSeq) state.lastSeq = data.latestSeq;
        if (activeTab === 'Devices') {
          fetchAuthorizedDevicesLocations(false);
        }
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
      if (document.visibilityState === 'visible') {
        if (state.companionToken) {
          triggerImmediateReconnect();
        }
        if (state.phoneLocationSharingEnabled && state.phoneLocationPermission === 'granted') {
          startForegroundPhoneLocationWatch();
        }
      } else {
        stopForegroundPhoneLocationWatch();
        if (state.companionToken && state.phoneLocationSharingEnabled && isValidCoord(state.phoneLatestLocation)) {
          const lastKnownSnap = Object.assign({}, state.phoneLatestLocation, { isLastKnown: true });
          state.phoneLatestLocation = lastKnownSnap;
          saveState();
          uploadCompanionPhoneLocationSnapshot(lastKnownSnap, 'attached', true);
        }
      }
    });
    window.addEventListener('pageshow', () => {
      if (state.companionToken) {
        triggerImmediateReconnect();
        if (state.phoneLocationSharingEnabled && state.phoneLocationPermission === 'granted') {
          startForegroundPhoneLocationWatch();
        }
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
