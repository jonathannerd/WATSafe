# Optional Owner Face Recognition — Architecture & Privacy Design

> **Status:** Design document only. Feature is **disabled** and intentionally excluded from WATSafe's main user interface.

## 1. Purpose & Scope

Users sometimes ask whether WATSafe could recognize the device owner's face via the built-in webcam to reduce friction when returning to a protected laptop or to suppress nuisance triggers while the owner sits nearby.

This document evaluates the technical feasibility, security boundaries, privacy requirements, and hardware limitations of optional local owner face recognition across macOS, Windows, iOS, and Android, and compares it against platform-native authentication (**Touch ID**, **Face ID**, and **Windows Hello**).

---

## 2. Face Detection vs. Identity Verification

A critical distinction separates **face detection** from **face identity verification**:

| Capability | What It Computes | Security Value |
| :--- | :--- | :--- |
| **Face detection** (e.g., Apple Vision `VNDetectFaceRectanglesRequest`, MediaPipe Face Detection) | Locates bounding boxes and landmarks showing *any* human face is in front of the webcam. | **Zero identity assurance.** Any passerby or thief leaning over the laptop satisfies face detection. Never use face presence to disarm or suppress alarms. |
| **2D RGB face embedding matching** (e.g., local MobileFaceNet / ArcFace ONNX embedding cosine similarity) | Extracts a 128-D or 512-D feature vector from an aligned RGB face crop and compares it against an enrolled owner vector. | **Convenience-tier signal only.** Standard 2D RGB webcams lack infrared depth and active liveness sensing, making them vulnerable to photo or screen presentation attacks. |
| **Hardware-backed biometric auth** (Apple Touch ID / Face ID via `LocalAuthentication`, Windows Hello via `UserConsentVerifier`) | Uses dedicated Secure Enclave / TPM hardware, capacitive fingerprint sensors, or structured-light / IR cameras managed by the OS. | **Cryptographic & spoof-resistant.** Suitable for security-critical disarming alongside WATSafe's PIN. |

### Core Security Rule
Even if optional RGB owner face recognition were enabled in a future experimental build:
1. **It must never replace the security PIN (or OS hardware biometrics) as sole proof to silence an already triggered theft alarm.**
2. **An unfamiliar face—or the absence of the owner's face—must never trigger an alarm on its own.** In libraries, cafés, classrooms, and open offices, bystanders routinely walk behind or glance toward a laptop webcam while the laptop itself remains completely untouched.

---

## 3. Permissible Role in Alarm Decision-Making

Because neither an unfamiliar face is proof of theft nor a 2D RGB match is proof against a printed photo, optional owner recognition could only act as a **strictly bounded convenience modifier**, never a standalone trigger or standalone alarm silencer:

- **What it must NEVER do:**
  - Trigger an alarm solely because an unknown face appears in the frame.
  - Retain, log, stream, or upload bystander face crops or embeddings.
  - Automatically disarm an active `alarming` siren without PIN or OS biometric verification.
- **What it could optionally do (if explicitly opted into):**
  - Extend the brief `"Movement detected — checking…"` confirmation window by 1–2 seconds when a high-confidence live-head-pose owner match is present during minor desk adjustments, prompting for Touch ID / Windows Hello / PIN on screen.

---

## 4. Explicit Local Owner Enrollment

If implemented in the future, owner enrollment must satisfy strict consent and transparency requirements:

1. **Opt-in only (Off by default):** Never enroll silently during normal arming or camera calibration.
2. **Clear pre-enrollment disclosure:** Plain-language notice explaining what is stored (a numeric mathematical template on this device only), how it is used, its limitations on standard webcams, and how to delete it at any time.
3. **Guided multi-pose local capture:** Capture 3–5 frontal and slight-angle frames under adequate room lighting, compute normalized L2 face embeddings in memory, average/cluster them into a single compact template (`<= 2 KB`), and **immediately zero/discard all raw image pixels** from memory.

---

## 5. Encrypted Local Template Storage & Instant Deletion

- **No raw images on disk:** Enrollment photographs and runtime video frames must never be written to disk, caches, crash reports, analytics, or logs.
- **Hardware-bound encryption at rest:**
  - Generate a random per-enrollment 256-bit AES-GCM data encryption key (DEK).
  - Store the DEK inside the platform's hardware-backed credential store (**macOS/iOS Keychain** with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, **Windows DPAPI / Credential Locker**, **Android Keystore**).
  - Encrypt the numeric embedding vector with AES-256-GCM and store the ciphertext locally on the protected device only.
- **Zero cloud or relay transmission:** Neither Neon PostgreSQL nor the Render relay (`watsafe-relay`) ever receives biometric templates, face match booleans, or camera frames.
- **One-tap user-initiated deletion:**
  - Toggling the feature off or tapping **Delete face data** must immediately delete both the Keychain/Keystore DEK (cryptographic erasure) and the encrypted template file, plus automatically purge templates during **Reset demo / Clear installation**.

---

## 6. Spoof Resistance, Lighting, Angle & False-Match Limitations

Standard laptop webcams (720p/1080p RGB without IR depth) have fundamental physical limitations that must be communicated honestly:

1. **Spoof / Presentation Attacks:** Without an infrared dot projector or stereo depth sensor, a high-resolution photo or tablet screen held in front of an RGB webcam can fool 2D embedding models. Passive RGB anti-spoofing (blink detection, micro-parallax during natural head motion, screen moiré/specular reflection checks) raises the bar against casual static photos but **cannot match hardware depth liveness**.
2. **Lighting & Backlighting:** Strong window backlighting, dim lecture halls, or screen-glow color casts shift facial contrast and increase **False Non-Match Rates (FNMR)**—causing the owner not to be recognized when legitimate.
3. **Camera Angle & Occlusion:** Laptop lids tilted steeply upward/downward, hats, glasses glare, scarves, or masks degrade landmark alignment. Lowering the cosine-similarity threshold to compensate would dangerously increase **False Match Rates (FMR)**, potentially matching a stranger.
4. **CPU & Battery Overhead:** Running neural face detection + alignment + embedding inference at 5–10 FPS consumes substantially more CPU/NPU power and thermal headroom than WATSafe's lightweight 64x48 grayscale ego-motion block analyzer.

---

## 7. Bystander Privacy Guarantees

Protected laptops are most often used in shared public spaces (campus libraries, study halls, coffee shops, coworking spaces). Processing webcam video in public carries heightened privacy obligations:

- **Ephemeral in-memory frame lifetime:** Every video frame must be processed in volatile RAM and overwritten within milliseconds, identical to WATSafe's existing grayscale motion analyzer.
- **Zero bystander template retention:** If a non-matching face enters the field of view, its temporary embedding vector is discarded immediately after the single cosine-similarity comparison—never cached, clustered, counted, or logged.
- **Zero network egress:** Inference runs 100% on-device; third-party cloud vision APIs are strictly prohibited.

---

## 8. Comparison with Native OS Authentication (Recommended Path)

Before investing in custom webcam face recognition, compare it directly against OS-native local authentication (`local_auth` / `LAContext` / Windows Hello):

| Criterion | Custom RGB Webcam Face Recognition | OS Authentication (Touch ID / Face ID / Windows Hello) |
| :--- | :--- | :--- |
| **Spoof resistance** | Weak on 2D RGB webcams; vulnerable to screen/photo replay without IR depth. | **Strong.** Hardware-backed capacitive fingerprint or IR structured-light depth sensors. |
| **Bystander privacy** | Continuously inspects faces in public spaces while armed. | **Zero bystander capture.** Triggered only when the user touches the sensor or explicitly initiates unlock. |
| **Biometric storage liability** | App must manage, encrypt, version, and purge custom neural templates. | **Zero biometric data in app.** Biometric templates never leave the Secure Enclave / TPM; WATSafe receives only a cryptographic pass/fail result. |
| **Works in dark rooms / with camera cover** | Fails completely when dark or when a physical privacy shutter covers the webcam. | **Touch ID / fingerprint works in total darkness** and with webcam privacy shutters closed. |
| **Battery & thermal impact** | Continuous neural inference while armed. | **Zero background battery cost** while armed. |

### Recommendation
Keep custom RGB webcam face recognition **disabled and out of the main UI**. If faster, lower-friction disarming is added alongside WATSafe's 6-digit PIN in a future release, **OS-native hardware authentication (macOS Touch ID, iOS Face ID / Touch ID, Windows Hello, Android BiometricPrompt)** delivers strictly superior security, spoof resistance, dark-room reliability, and bystander privacy without ever storing biometric templates in WATSafe.
