import AVFoundation
import Cocoa
import CoreLocation
import FlutterMacOS
import IOKit.ps
import Security
import UserNotifications

class MainFlutterWindow: NSWindow {
  private var cameraBridge: MacOSCameraMotionBridge?
  private var audioBridge: MacOSAudioAlarmBridge?
  private var secureStorageBridge: MacOSSecureStorageBridge?
  private var locationBridge: MacOSLocationBridge?
  private var notificationBridge: MacOSLocalNotificationBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 420, height: 640)
    self.title = "WATSafe"

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    cameraBridge = MacOSCameraMotionBridge(messenger: messenger)
    audioBridge = MacOSAudioAlarmBridge(messenger: messenger)
    secureStorageBridge = MacOSSecureStorageBridge(messenger: messenger)
    locationBridge = MacOSLocationBridge(messenger: messenger)
    notificationBridge = MacOSLocalNotificationBridge(messenger: messenger)

    super.awakeFromNib()
  }
}

// MARK: - macOS Native Audio Alarm Bridge

final class MacOSAudioAlarmBridge {
  private let channel: FlutterMethodChannel
  private var audioPlayer: AVAudioPlayer?
  private var testStopWorkItem: DispatchWorkItem?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "dev.watsafe/audio_alarm",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "startLoopingAlarm":
      let volume = (args?["volume"] as? NSNumber)?.floatValue ?? 0.85
      let typedBytes = args?["wavBytes"] as? FlutterStandardTypedData
      startPlayback(
        wavData: typedBytes?.data,
        volume: volume,
        maxDurationMs: nil,
        result: result
      )

    case "startTestAlarm":
      let volume = (args?["volume"] as? NSNumber)?.floatValue ?? 0.85
      let maxDurationMs = (args?["maxDurationMs"] as? NSNumber)?.intValue ?? 5000
      let typedBytes = args?["wavBytes"] as? FlutterStandardTypedData
      startPlayback(
        wavData: typedBytes?.data,
        volume: volume,
        maxDurationMs: min(maxDurationMs, 5000),
        result: result
      )

    case "stopAlarm":
      stopPlayback()
      result(nil)

    case "setVolume":
      let volume = (args?["volume"] as? NSNumber)?.floatValue ?? 0.85
      audioPlayer?.volume = max(0.0, min(1.0, volume))
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startPlayback(
    wavData: Data?,
    volume: Float,
    maxDurationMs: Int?,
    result: @escaping FlutterResult
  ) {
    stopPlayback()
    guard let data = wavData, !data.isEmpty else {
      NSSound.beep()
      result(nil)
      return
    }

    do {
      let player = try AVAudioPlayer(data: data)
      player.numberOfLoops = -1
      player.volume = max(0.0, min(1.0, volume))
      player.prepareToPlay()
      player.play()
      audioPlayer = player

      if let durationMs = maxDurationMs {
        let workItem = DispatchWorkItem { [weak self] in
          self?.stopPlayback()
        }
        testStopWorkItem = workItem
        DispatchQueue.main.asyncAfter(
          deadline: .now() + .milliseconds(durationMs),
          execute: workItem
        )
      }
      result(nil)
    } catch {
      NSSound.beep()
      result(
        FlutterError(
          code: "AUDIO_INIT_FAILED",
          message: "AVAudioPlayer failed to start: \(error.localizedDescription)",
          details: nil
        )
      )
    }
  }

  private func stopPlayback() {
    testStopWorkItem?.cancel()
    testStopWorkItem = nil
    audioPlayer?.stop()
    audioPlayer = nil
  }
}

// MARK: - macOS Native Secure Storage Bridge (Keychain + Protected File Fallback)

final class MacOSSecureStorageBridge {
  private let channel: FlutterMethodChannel
  private let serviceName = "dev.watsafe.temp.watsafe.pin"
  private let accountName = "pin_pbkdf2_record"

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "dev.watsafe/secure_storage",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "readPinRecord":
      if let keychainValue = readFromKeychain(account: accountName) {
        result(keychainValue)
        return
      }
      result(readFromProtectedFile(fileName: "secure_pin_record.json"))

    case "writePinRecord":
      let args = call.arguments as? [String: Any]
      guard let payload = args?["payload"] as? String else {
        result(
          FlutterError(
            code: "INVALID_ARGUMENTS",
            message: "Missing payload for writePinRecord",
            details: nil
          )
        )
        return
      }
      let keychainOk = writeToKeychain(account: accountName, payload: payload)
      writeToProtectedFile(fileName: "secure_pin_record.json", payload: payload)
      if keychainOk {
        result("macOS Security Keychain (PBKDF2-HMAC-SHA256)")
      } else {
        result("macOS Sandboxed Application Support (0600 PBKDF2-HMAC-SHA256)")
      }

    case "deletePinRecord":
      deleteFromKeychain(account: accountName)
      deleteProtectedFile(fileName: "secure_pin_record.json")
      result(nil)

    case "readSecureSecret":
      let args = call.arguments as? [String: Any]
      let key = sanitizeKey(args?["key"] as? String ?? "default")
      if let keychainValue = readFromKeychain(account: "secret_\(key)") {
        result(keychainValue)
        return
      }
      result(readFromProtectedFile(fileName: "secure_secret_\(key).json"))

    case "writeSecureSecret":
      let args = call.arguments as? [String: Any]
      let key = sanitizeKey(args?["key"] as? String ?? "default")
      guard let payload = args?["payload"] as? String else {
        result(
          FlutterError(
            code: "INVALID_ARGUMENTS",
            message: "Missing payload for writeSecureSecret",
            details: nil
          )
        )
        return
      }
      _ = writeToKeychain(account: "secret_\(key)", payload: payload)
      writeToProtectedFile(fileName: "secure_secret_\(key).json", payload: payload)
      result("ok")

    case "deleteSecureSecret":
      let args = call.arguments as? [String: Any]
      let key = sanitizeKey(args?["key"] as? String ?? "default")
      deleteFromKeychain(account: "secret_\(key)")
      deleteProtectedFile(fileName: "secure_secret_\(key).json")
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func sanitizeKey(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    let filtered = raw.unicodeScalars.filter { allowed.contains($0) }
    let out = String(String.UnicodeScalarView(filtered))
    return out.isEmpty ? "default" : out
  }

  private func readFromKeychain(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private func writeToKeychain(account: String, payload: String) -> Bool {
    guard let data = payload.data(using: .utf8) else {
      return false
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)

    var attributes = query
    attributes[kSecValueData as String] = data
    let status = SecItemAdd(attributes as CFDictionary, nil)
    return status == errSecSuccess
  }

  private func deleteFromKeychain(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }

  private func protectedFileURL(fileName: String) -> URL? {
    guard
      let base = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      return nil
    }
    let dir = base.appendingPathComponent("dev.watsafe.temp.watsafe", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(fileName)
  }

  private func readFromProtectedFile(fileName: String) -> String? {
    guard let url = protectedFileURL(fileName: fileName),
      FileManager.default.fileExists(atPath: url.path)
    else {
      return nil
    }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  private func writeToProtectedFile(fileName: String, payload: String) {
    guard let url = protectedFileURL(fileName: fileName) else {
      return
    }
    try? payload.write(to: url, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
  }

  private func deleteProtectedFile(fileName: String) {
    guard let url = protectedFileURL(fileName: fileName) else {
      return
    }
    try? FileManager.default.removeItem(at: url)
  }
}

// MARK: - macOS Native AVFoundation Camera Scene-Motion Bridge

final class MacOSCameraMotionBridge: NSObject, FlutterStreamHandler,
  AVCaptureVideoDataOutputSampleBufferDelegate
{
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private let processingQueue = DispatchQueue(
    label: "dev.watsafe.camera.motion",
    qos: .userInitiated
  )

  private var eventSink: FlutterEventSink?
  private var captureSession: AVCaptureSession?
  private var activeSessionId: String?
  private var pausedSessionId: String?
  private var pendingStartResult: FlutterResult?
  private var pendingDeviceName: String = "macOS Camera"
  private var firstFrameTimeoutWorkItem: DispatchWorkItem?
  private var hasDeliveredFirstFrame: Bool = false

  private var motionThreshold: Double = 0.095
  private var calibrationDurationMs: Int = 1500
  private var persistenceFramesRequired: Int = 3
  private var downsampleWidth: Int = 64
  private var downsampleHeight: Int = 48

  private var sessionStartTimeMs: Int64 = 0
  private var isCalibrationDone: Bool = false
  private var referenceGrid: [Float] = []
  private var previousGrid: [Float] = []
  private var recentGrids: [[Float]] = []
  private var settledBlockStreak: [Int] = [Int](repeating: 0, count: 16)
  private var previousMean255: Float = 0
  private var prevMeanFlowDx: Double = 0
  private var prevMeanFlowDy: Double = 0
  private var hasPrevMeanFlow: Bool = false
  private var wasOnAcPower: Bool?
  private var lastAcUnplugTimeMs: Int64 = 0
  private var consecutiveAboveThreshold: Int = 0
  private var consecutivePoorInputFrames: Int = 0
  private var isInputDegraded: Bool = false
  private var processedFrameCount: Int = 0
  private var lastFrameProcessedTime: CFAbsoluteTime = 0

  private var sleepObserver: NSObjectProtocol?
  private var wakeObserver: NSObjectProtocol?
  private var runtimeErrorObserver: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "dev.watsafe/macos_camera",
      binaryMessenger: messenger
    )
    eventChannel = FlutterEventChannel(
      name: "dev.watsafe/macos_camera_events",
      binaryMessenger: messenger
    )
    super.init()

    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call: call, result: result)
    }
    eventChannel.setStreamHandler(self)
    registerWorkspaceLifecycleObservers()
  }

  deinit {
    if let sleepObserver = sleepObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
    }
    if let wakeObserver = wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
    }
    if let runtimeErrorObserver = runtimeErrorObserver {
      NotificationCenter.default.removeObserver(runtimeErrorObserver)
    }
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  private func registerWorkspaceLifecycleObservers() {
    let center = NSWorkspace.shared.notificationCenter
    sleepObserver = center.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.processingQueue.async { [weak self] in
        guard let self = self, let sessionId = self.activeSessionId else { return }
        self.pausedSessionId = sessionId
        self.stopCaptureOnQueue()
        self.emitEvent([
          "sessionId": sessionId,
          "eventType": "lifecyclePaused",
          "summary": "macOS system entering sleep; webcam capture paused.",
          "timestampMs": Int64(Date().timeIntervalSince1970 * 1000),
        ])
      }
    }

    wakeObserver = center.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.processingQueue.async { [weak self] in
        guard let self = self else { return }
        let resumeId = self.activeSessionId ?? self.pausedSessionId
        self.pausedSessionId = nil
        guard let sessionId = resumeId else { return }
        self.emitEvent([
          "sessionId": sessionId,
          "eventType": "lifecycleResumed",
          "summary": "macOS system woke from sleep; webcam monitoring ready to resume.",
          "timestampMs": Int64(Date().timeIntervalSince1970 * 1000),
        ])
      }
    }
  }

  private func handleMethodCall(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "checkCapability":
      result(checkCapabilityMap())

    case "requestPermission":
      requestCameraPermission(result: result)

    case "startMonitoring":
      let args = call.arguments as? [String: Any] ?? [:]
      startMonitoring(args: args, result: result)

    case "updateSensitivity":
      let args = call.arguments as? [String: Any] ?? [:]
      if let threshold = (args["motionScoreThreshold"] as? NSNumber)?.doubleValue {
        processingQueue.async { [weak self] in
          self?.motionThreshold = max(0.02, min(0.50, threshold))
        }
      }
      result(nil)

    case "stopMonitoring":
      processingQueue.async { [weak self] in
        self?.stopCaptureOnQueue()
        DispatchQueue.main.async {
          result(nil)
        }
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func discoverDefaultVideoDevice() -> AVCaptureDevice? {
    if let defaultDevice = AVCaptureDevice.default(for: .video) {
      return defaultDevice
    }
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
      mediaType: .video,
      position: .unspecified
    )
    return discovery.devices.first
  }

  private func permissionStatusString(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized:
      return "granted"
    case .notDetermined:
      return "notDetermined"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    @unknown default:
      return "notDetermined"
    }
  }

  private func checkCapabilityMap() -> [String: Any] {
    let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
    let permString = permissionStatusString(authStatus)
    let device = discoverDefaultVideoDevice()
    let hasHardware = (device != nil)

    return [
      "hasCameraHardware": hasHardware,
      "deviceName": device?.localizedName ?? "No Camera Detected",
      "permissionStatus": permString,
      "detail": hasHardware
        ? "Camera device \(device?.localizedName ?? "Camera") discovered via AVFoundation."
        : "No video capture devices reported by AVCaptureDevice.DiscoverySession.",
    ]
  }

  private func requestCameraPermission(result: @escaping FlutterResult) {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    if status == .notDetermined {
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          result(granted ? "granted" : "denied")
        }
      }
    } else {
      result(permissionStatusString(status))
    }
  }

  private func startMonitoring(
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    let sessionId = (args["sessionId"] as? String) ?? "session_default"
    let threshold =
      (args["motionScoreThreshold"] as? NSNumber)?.doubleValue ?? 0.095
    let calibrationMs =
      (args["calibrationDurationMs"] as? NSNumber)?.intValue ?? 1500
    let persistenceFrames =
      (args["persistenceFramesRequired"] as? NSNumber)?.intValue ?? 3
    let width = (args["downsampleWidth"] as? NSNumber)?.intValue ?? 64
    let height = (args["downsampleHeight"] as? NSNumber)?.intValue ?? 48

    let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
    guard authStatus == .authorized else {
      let code = authStatus == .denied || authStatus == .restricted
        ? "PERMISSION_DENIED"
        : "PERMISSION_NOT_GRANTED"
      result([
        "started": false,
        "message": "Camera permission is not granted (\(permissionStatusString(authStatus))).",
        "errorCode": code,
      ])
      return
    }

    guard let device = discoverDefaultVideoDevice() else {
      result([
        "started": false,
        "message": "No macOS camera hardware found.",
        "errorCode": "NO_CAMERA_HARDWARE",
      ])
      return
    }

    if device.isInUseByAnotherApplication {
      result([
        "started": false,
        "message": "\(device.localizedName) is currently in use by another application.",
        "errorCode": "CAMERA_BUSY",
      ])
      return
    }

    processingQueue.async { [weak self] in
      guard let self = self else { return }
      self.pausedSessionId = nil
      self.stopCaptureOnQueue()

      let session = AVCaptureSession()
      session.beginConfiguration()
      if session.canSetSessionPreset(.low) {
        session.sessionPreset = .low
      } else if session.canSetSessionPreset(.medium) {
        session.sessionPreset = .medium
      }

      do {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
          session.commitConfiguration()
          let busy = device.isInUseByAnotherApplication
          DispatchQueue.main.async {
            result([
              "started": false,
              "message": busy
                ? "\(device.localizedName) is currently in use by another application."
                : "Cannot attach camera device input to AVCaptureSession.",
              "errorCode": busy ? "CAMERA_BUSY" : "INPUT_ATTACH_FAILED",
            ])
          }
          return
        }
        session.addInput(input)
      } catch {
        session.commitConfiguration()
        let desc = error.localizedDescription.lowercased()
        let busy = device.isInUseByAnotherApplication
          || desc.contains("in use")
          || desc.contains("busy")
          || desc.contains("another application")
        DispatchQueue.main.async {
          result([
            "started": false,
            "message": busy
              ? "\(device.localizedName) is currently in use by another application."
              : "Failed to open camera input: \(error.localizedDescription)",
            "errorCode": busy ? "CAMERA_BUSY" : "INPUT_OPEN_ERROR",
          ])
        }
        return
      }

      let output = AVCaptureVideoDataOutput()
      output.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
      ]
      output.alwaysDiscardsLateVideoFrames = true
      output.setSampleBufferDelegate(self, queue: self.processingQueue)

      guard session.canAddOutput(output) else {
        session.commitConfiguration()
        DispatchQueue.main.async {
          result([
            "started": false,
            "message": "Cannot attach video data output to AVCaptureSession.",
            "errorCode": "OUTPUT_ATTACH_FAILED",
          ])
        }
        return
      }
      session.addOutput(output)
      session.commitConfiguration()

      self.activeSessionId = sessionId
      self.pendingDeviceName = device.localizedName
      self.pendingStartResult = result
      self.hasDeliveredFirstFrame = false
      self.motionThreshold = max(0.02, min(0.50, threshold))
      self.calibrationDurationMs = max(500, calibrationMs)
      self.persistenceFramesRequired = max(1, persistenceFrames)
      self.downsampleWidth = max(16, min(160, width))
      self.downsampleHeight = max(12, min(120, height))
      self.sessionStartTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
      self.isCalibrationDone = false
      self.referenceGrid = []
      self.previousGrid = []
      self.recentGrids = []
      self.settledBlockStreak = [Int](repeating: 0, count: 16)
      self.previousMean255 = 0
      self.prevMeanFlowDx = 0
      self.prevMeanFlowDy = 0
      self.hasPrevMeanFlow = false
      self.wasOnAcPower = self.queryIsRunningOnAcPower()
      self.lastAcUnplugTimeMs = 0
      self.consecutiveAboveThreshold = 0
      self.consecutivePoorInputFrames = 0
      self.isInputDegraded = false
      self.processedFrameCount = 0
      self.lastFrameProcessedTime = 0

      self.runtimeErrorObserver = NotificationCenter.default.addObserver(
        forName: .AVCaptureSessionRuntimeError,
        object: session,
        queue: nil
      ) { [weak self] notification in
        let errorObj = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let messageText = errorObj?.localizedDescription ?? "Unknown AVFoundation error"
        self?.processingQueue.async { [weak self] in
          guard let self = self, let activeId = self.activeSessionId else { return }
          let lower = messageText.lowercased()
          let isBusy = device.isInUseByAnotherApplication
            || lower.contains("in use")
            || lower.contains("busy")
          if let pending = self.pendingStartResult {
            self.pendingStartResult = nil
            self.stopCaptureOnQueue()
            DispatchQueue.main.async {
              pending([
                "started": false,
                "message": isBusy
                  ? "\(device.localizedName) is currently in use by another application."
                  : "Camera capture failed during startup: \(messageText)",
                "errorCode": isBusy ? "CAMERA_BUSY" : "AVCAPTURE_RUNTIME_ERROR",
              ])
            }
            return
          }
          self.stopCaptureOnQueue()
          self.emitEvent([
            "sessionId": activeId,
            "eventType": "detectorFailed",
            "summary": "Camera capture runtime error: \(messageText)",
            "errorCode": isBusy ? "CAMERA_BUSY" : "AVCAPTURE_RUNTIME_ERROR",
            "timestampMs": Int64(Date().timeIntervalSince1970 * 1000),
          ])
        }
      }

      self.captureSession = session
      session.startRunning()

      guard session.isRunning else {
        let pending = self.pendingStartResult
        self.pendingStartResult = nil
        self.stopCaptureOnQueue()
        let busy = device.isInUseByAnotherApplication
        DispatchQueue.main.async {
          pending?([
            "started": false,
            "message": busy
              ? "\(device.localizedName) is currently in use by another application."
              : "AVCaptureSession failed to enter running state.",
            "errorCode": busy ? "CAMERA_BUSY" : "SESSION_NOT_RUNNING",
          ])
        }
        return
      }

      // Only report webcam monitoring as active once video frames are arriving.
      let timeoutItem = DispatchWorkItem { [weak self] in
        guard let self = self, !self.hasDeliveredFirstFrame else { return }
        guard let pending = self.pendingStartResult else { return }
        self.pendingStartResult = nil
        let busy = device.isInUseByAnotherApplication
        self.stopCaptureOnQueue()
        DispatchQueue.main.async {
          pending([
            "started": false,
            "message": busy
              ? "\(device.localizedName) is in use by another application and delivered no frames."
              : "Camera opened on \(device.localizedName), but no video frames arrived within 4 seconds.",
            "errorCode": busy ? "CAMERA_BUSY" : "FRAME_TIMEOUT",
          ])
        }
      }
      self.firstFrameTimeoutWorkItem = timeoutItem
      self.processingQueue.asyncAfter(deadline: .now() + 4.0, execute: timeoutItem)
    }
  }

  private func stopCaptureOnQueue() {
    firstFrameTimeoutWorkItem?.cancel()
    firstFrameTimeoutWorkItem = nil
    if let pending = pendingStartResult {
      pendingStartResult = nil
      DispatchQueue.main.async {
        pending([
          "started": false,
          "message": "Camera startup cancelled before first frame.",
          "errorCode": "STARTUP_CANCELLED",
        ])
      }
    }
    if let runtimeErrorObserver = runtimeErrorObserver {
      NotificationCenter.default.removeObserver(runtimeErrorObserver)
      self.runtimeErrorObserver = nil
    }
    if let session = captureSession {
      if session.isRunning {
        session.stopRunning()
      }
    }
    captureSession = nil
    activeSessionId = nil
    hasDeliveredFirstFrame = false
    referenceGrid = []
    previousGrid = []
    recentGrids = []
    settledBlockStreak = [Int](repeating: 0, count: 16)
    previousMean255 = 0
    hasPrevMeanFlow = false
    wasOnAcPower = nil
    lastAcUnplugTimeMs = 0
    consecutiveAboveThreshold = 0
  }

  private func queryIsRunningOnAcPower() -> Bool? {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sourceType = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
    else {
      return nil
    }
    return sourceType == (kIOPMACPowerKey as String)
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let sessionId = activeSessionId else { return }

    let now = CFAbsoluteTimeGetCurrent()
    // Process ~8 frames per second off the UI thread (never throttle the very first frame).
    if hasDeliveredFirstFrame && (now - lastFrameProcessedTime < 0.12) {
      return
    }

    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }

    let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
    let srcWidth = isPlanar
      ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
      : CVPixelBufferGetWidth(pixelBuffer)
    let srcHeight = isPlanar
      ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
      : CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = isPlanar
      ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
      : CVPixelBufferGetBytesPerRow(pixelBuffer)
    let rawBase = isPlanar
      ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
      : CVPixelBufferGetBaseAddress(pixelBuffer)

    guard
      srcWidth > 0,
      srcHeight > 0,
      bytesPerRow > 0,
      let baseAddress = rawBase
    else {
      return
    }

    lastFrameProcessedTime = now
    let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
    let gridW = downsampleWidth
    let gridH = downsampleHeight
    let count = gridW * gridH
    var currentGrid = [Float](repeating: 0, count: count)
    var lumSum: Float = 0

    for gy in 0..<gridH {
      let sy = (gy * srcHeight) / gridH
      let rowOffset = sy * bytesPerRow
      for gx in 0..<gridW {
        let sx = (gx * srcWidth) / gridW
        let y: Float
        if isPlanar {
          y = Float(ptr[rowOffset + sx])
        } else {
          let pixelOffset = rowOffset + (sx * 4)
          let b = Int(ptr[pixelOffset])
          let g = Int(ptr[pixelOffset + 1])
          let r = Int(ptr[pixelOffset + 2])
          y = Float((77 * r + 150 * g + 29 * b) >> 8)
        }
        let idx = gy * gridW + gx
        currentGrid[idx] = y
        lumSum += y
      }
    }

    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    if !hasDeliveredFirstFrame {
      hasDeliveredFirstFrame = true
      sessionStartTimeMs = nowMs
      firstFrameTimeoutWorkItem?.cancel()
      firstFrameTimeoutWorkItem = nil
      let deviceLabel = pendingDeviceName
      emitEvent([
        "sessionId": sessionId,
        "eventType": "calibrationStarted",
        "summary": "Calibrating baseline scene on \(deviceLabel)...",
        "threshold": motionThreshold,
        "timestampMs": nowMs,
      ])
      if let pending = pendingStartResult {
        pendingStartResult = nil
        DispatchQueue.main.async {
          pending([
            "started": true,
            "message": "Monitoring active on \(deviceLabel).",
          ])
        }
      }
    }

    let currMean = lumSum / Float(count)
    let normalizedLuminance = Double(currMean / 255.0)

    var currDevSum: Float = 0
    for val in currentGrid {
      currDevSum += abs(val - currMean)
    }
    let currMad = currDevSum / Float(count)
    let normalizedDeviation = Double(currMad / 255.0)

    processedFrameCount += 1

    // Check for covered lens / pitch-black poor input
    if normalizedLuminance < 0.025 || normalizedDeviation < 0.007 {
      consecutivePoorInputFrames += 1
      if consecutivePoorInputFrames >= 8 && !isInputDegraded {
        isInputDegraded = true
        emitEvent([
          "sessionId": sessionId,
          "eventType": "poorInputWarning",
          "summary":
            "Low light or covered camera lens detected (brightness \(Int(normalizedLuminance * 100))%). Scene-motion sensitivity is degraded.",
          "averageLuminance": normalizedLuminance,
          "threshold": motionThreshold,
          "timestampMs": nowMs,
        ])
      }
    } else if normalizedLuminance >= 0.04 && normalizedDeviation >= 0.012 {
      consecutivePoorInputFrames = 0
      if isInputDegraded {
        isInputDegraded = false
        emitEvent([
          "sessionId": sessionId,
          "eventType": "inputRecovered",
          "summary": "Camera lighting and scene contrast restored.",
          "averageLuminance": normalizedLuminance,
          "threshold": motionThreshold,
          "timestampMs": nowMs,
        ])
      }
    }

    // Initialize or adapt reference baseline during startup calibration interval
    if referenceGrid.count != count || previousGrid.count != count {
      referenceGrid = currentGrid
      previousGrid = currentGrid
      previousMean255 = currMean
      return
    }

    let elapsedMs = nowMs - sessionStartTimeMs
    if !isCalibrationDone {
      for i in 0..<count {
        referenceGrid[i] = (0.65 * referenceGrid[i]) + (0.35 * currentGrid[i])
        previousGrid[i] = currentGrid[i]
      }
      previousMean255 = currMean
      if elapsedMs >= Int64(calibrationDurationMs) && processedFrameCount >= 4 {
        isCalibrationDone = true
        recentGrids = [referenceGrid]
        emitEvent([
          "sessionId": sessionId,
          "eventType": "calibrationCompleted",
          "summary": "Scene baseline calibrated. Ego-motion optical flow filtering enabled.",
          "motionScore": 0.0,
          "threshold": motionThreshold,
          "averageLuminance": normalizedLuminance,
          "consecutiveFrames": 0,
          "timestampMs": nowMs,
        ])
      }
      return
    }

    // Track weak supporting signal: recent AC charger unplug (never alarms on its own).
    if let nowAc = queryIsRunningOnAcPower() {
      if wasOnAcPower == true && !nowAc {
        lastAcUnplugTimeMs = nowMs
      }
      wasOnAcPower = nowAc
    }
    let acPowerUnpluggedRecently =
      lastAcUnplugTimeMs > 0 && (nowMs - lastAcUnplugTimeMs) <= 8000

    let windowGrid = recentGrids.first ?? previousGrid
    let hasWindowSpan = recentGrids.count >= 3

    // Per-block zero-mean & affine illumination normalization + 4x4 Lucas-Kanade ego-motion
    let blocksX = 4
    let blocksY = 4
    let totalBlocks = blocksX * blocksY
    var blockCurrSum = [Double](repeating: 0, count: totalBlocks)
    var blockRefSum = [Double](repeating: 0, count: totalBlocks)
    var blockPrevSum = [Double](repeating: 0, count: totalBlocks)
    var blockWinSum = [Double](repeating: 0, count: totalBlocks)
    var blockPixelCount = [Int](repeating: 0, count: totalBlocks)

    for gy in 0..<gridH {
      let by = min(blocksY - 1, (gy * blocksY) / max(1, gridH))
      for gx in 0..<gridW {
        let bx = min(blocksX - 1, (gx * blocksX) / max(1, gridW))
        let bIdx = by * blocksX + bx
        let i = gy * gridW + gx
        blockCurrSum[bIdx] += Double(currentGrid[i])
        blockRefSum[bIdx] += Double(referenceGrid[i])
        blockPrevSum[bIdx] += Double(previousGrid[i])
        blockWinSum[bIdx] += Double(windowGrid[i])
        blockPixelCount[bIdx] += 1
      }
    }

    var blockCurrMean = [Double](repeating: 0, count: totalBlocks)
    var blockRefMean = [Double](repeating: 0, count: totalBlocks)
    var blockPrevMean = [Double](repeating: 0, count: totalBlocks)
    var blockWinMean = [Double](repeating: 0, count: totalBlocks)
    for b in 0..<totalBlocks where blockPixelCount[b] > 0 {
      let n = Double(blockPixelCount[b])
      blockCurrMean[b] = blockCurrSum[b] / n
      blockRefMean[b] = blockRefSum[b] / n
      blockPrevMean[b] = blockPrevSum[b] / n
      blockWinMean[b] = blockWinSum[b] / n
    }

    var blockCurrDevSum = [Double](repeating: 0, count: totalBlocks)
    var blockRefDevSum = [Double](repeating: 0, count: totalBlocks)
    var blockPrevDevSum = [Double](repeating: 0, count: totalBlocks)
    for gy in 0..<gridH {
      let by = min(blocksY - 1, (gy * blocksY) / max(1, gridH))
      for gx in 0..<gridW {
        let bx = min(blocksX - 1, (gx * blocksX) / max(1, gridW))
        let bIdx = by * blocksX + bx
        let i = gy * gridW + gx
        blockCurrDevSum[bIdx] += abs(Double(currentGrid[i]) - blockCurrMean[bIdx])
        blockRefDevSum[bIdx] += abs(Double(referenceGrid[i]) - blockRefMean[bIdx])
        blockPrevDevSum[bIdx] += abs(Double(previousGrid[i]) - blockPrevMean[bIdx])
      }
    }

    var blockGainToRef = [Double](repeating: 1.0, count: totalBlocks)
    var blockGainToPrev = [Double](repeating: 1.0, count: totalBlocks)
    for b in 0..<totalBlocks where blockPixelCount[b] > 0 {
      let n = Double(blockPixelCount[b])
      let cMad = blockCurrDevSum[b] / n
      let rMad = blockRefDevSum[b] / n
      let pMad = blockPrevDevSum[b] / n
      if cMad > 2.5 && rMad > 2.5 {
        blockGainToRef[b] = max(0.66, min(1.50, rMad / cMad))
      }
      if cMad > 2.5 && pMad > 2.5 {
        blockGainToPrev[b] = max(0.74, min(1.35, pMad / cMad))
      }
    }

    var blockRefDiffSum = [Double](repeating: 0, count: totalBlocks)
    var blockStepDiffSum = [Double](repeating: 0, count: totalBlocks)
    var blockWinDiffSum = [Double](repeating: 0, count: totalBlocks)
    var blockRefGradSum = [Double](repeating: 0, count: totalBlocks)
    var blockCurrGradSum = [Double](repeating: 0, count: totalBlocks)
    var blockGradCount = [Int](repeating: 0, count: totalBlocks)

    var normRefDiffSum: Double = 0
    var normStepDiffSum: Double = 0
    for gy in 0..<gridH {
      let by = min(blocksY - 1, (gy * blocksY) / max(1, gridH))
      for gx in 0..<gridW {
        let bx = min(blocksX - 1, (gx * blocksX) / max(1, gridW))
        let bIdx = by * blocksX + bx
        let i = gy * gridW + gx

        let currVal = Double(currentGrid[i])
        let refVal = Double(referenceGrid[i])
        let prevVal = Double(previousGrid[i])
        let winVal = Double(windowGrid[i])

        let normCurrToRef = (currVal - blockCurrMean[bIdx]) * blockGainToRef[bIdx]
        let refCentered = refVal - blockRefMean[bIdx]
        let refDelta = abs(normCurrToRef - refCentered)

        let normCurrToPrev = (currVal - blockCurrMean[bIdx]) * blockGainToPrev[bIdx]
        let prevCentered = prevVal - blockPrevMean[bIdx]
        let stepDelta = abs(normCurrToPrev - prevCentered)

        let winShift = blockCurrMean[bIdx] - blockWinMean[bIdx]
        let winDelta = abs((currVal - winVal) - winShift)

        normRefDiffSum += refDelta
        normStepDiffSum += stepDelta
        blockRefDiffSum[bIdx] += refDelta
        blockStepDiffSum[bIdx] += stepDelta
        blockWinDiffSum[bIdx] += winDelta

        if gx + 1 < gridW && gy + 1 < gridH {
          let gxDiff = abs(refVal - Double(referenceGrid[i + 1]))
          let gyDiff = abs(refVal - Double(referenceGrid[i + gridW]))
          blockRefGradSum[bIdx] += 0.5 * (gxDiff + gyDiff)

          let cgxDiff = abs(currVal - Double(currentGrid[i + 1]))
          let cgyDiff = abs(currVal - Double(currentGrid[i + gridW]))
          blockCurrGradSum[bIdx] += 0.5 * (cgxDiff + cgyDiff)
          blockGradCount[bIdx] += 1
        }
      }
    }

    let staticBlockThreshold = max(0.020, motionThreshold * 0.36)
    let activeBlockThreshold = max(0.024, motionThreshold * 0.48)
    let blockW = gridW / blocksX
    let blockH = gridH / blocksY

    var texturedRefBlocks = 0
    var anchoredTexturedBlocks = 0
    var texturedPerimeterBlocks = 0
    var anchoredPerimeterBlocks = 0
    var activeMovingBlocks = 0
    var texturedRefScoreSum = 0.0
    var dxList: [Double] = []
    var dyList: [Double] = []
    var bxList: [Int] = []
    var byList: [Int] = []
    var quadrantActivity = [Int](repeating: 0, count: 4)

    var winDxList: [Double] = []
    var winDyList: [Double] = []
    var winBxList: [Int] = []
    var winByList: [Int] = []
    var winQuadrantActivity = [Int](repeating: 0, count: 4)

    for by in 0..<blocksY {
      for bx in 0..<blocksX {
        let b = by * blocksX + bx
        let pxCount = blockPixelCount[b]
        if pxCount <= 0 { continue }

        let refScore = blockRefDiffSum[b] / Double(pxCount * 255)
        let stepScore = blockStepDiffSum[b] / Double(pxCount * 255)
        let winScore = blockWinDiffSum[b] / Double(pxCount * 255)
        let meanGrad = blockGradCount[b] > 0
          ? (blockRefGradSum[b] / Double(blockGradCount[b]))
          : 0.0
        let currGrad = blockGradCount[b] > 0
          ? (blockCurrGradSum[b] / Double(blockGradCount[b]))
          : 0.0
        let isTextured = meanGrad >= 3.2
        let isPerimeter = bx == 0 || bx == (blocksX - 1) || by == 0 || by == (blocksY - 1)

        if stepScore < 0.010 {
          settledBlockStreak[b] += 1
        } else {
          settledBlockStreak[b] = 0
        }

        if isTextured {
          texturedRefBlocks += 1
          texturedRefScoreSum += refScore
          if isPerimeter { texturedPerimeterBlocks += 1 }
          if refScore < staticBlockThreshold && stepScore < 0.016 {
            anchoredTexturedBlocks += 1
            if isPerimeter { anchoredPerimeterBlocks += 1 }
          }
        }

        let blockStepShift = blockCurrMean[b] - blockPrevMean[b]
        var blockTranslated = false
        if isTextured && currGrad >= 2.4 && stepScore >= 0.008 && blockW >= 6 && blockH >= 6 {
          let flow = estimateLucasKanadeFlow(
            previous: previousGrid,
            current: currentGrid,
            gridW: gridW,
            gridH: gridH,
            stepMeanShift: blockStepShift,
            x0: bx * blockW,
            y0: by * blockH,
            w: blockW,
            h: blockH,
            minMagnitude: 0.32
          ) ?? estimateBlockTranslation(
            previous: previousGrid,
            current: currentGrid,
            gridW: gridW,
            gridH: gridH,
            stepMeanShift: blockStepShift,
            x0: bx * blockW,
            y0: by * blockH,
            w: blockW,
            h: blockH
          )
          if let flow = flow {
            blockTranslated = true
            dxList.append(flow.0)
            dyList.append(flow.1)
            bxList.append(bx)
            byList.append(by)
          }
        }

        if hasWindowSpan && isTextured && currGrad >= 2.6 && winScore >= 0.010 && blockW >= 6 && blockH >= 6 {
          let winShift = blockCurrMean[b] - blockWinMean[b]
          let winFlow = estimateLucasKanadeFlow(
            previous: windowGrid,
            current: currentGrid,
            gridW: gridW,
            gridH: gridH,
            stepMeanShift: winShift,
            x0: bx * blockW,
            y0: by * blockH,
            w: blockW,
            h: blockH,
            minMagnitude: 0.36
          ) ?? estimateBlockTranslation(
            previous: windowGrid,
            current: currentGrid,
            gridW: gridW,
            gridH: gridH,
            stepMeanShift: winShift,
            x0: bx * blockW,
            y0: by * blockH,
            w: blockW,
            h: blockH
          )
          if let winFlow = winFlow {
            winDxList.append(winFlow.0)
            winDyList.append(winFlow.1)
            winBxList.append(bx)
            winByList.append(by)
            let qx = bx >= 2 ? 1 : 0
            let qy = by >= 2 ? 1 : 0
            winQuadrantActivity[qy * 2 + qx] += 1
          }
        }

        if (refScore >= activeBlockThreshold && stepScore >= 0.012) || blockTranslated {
          activeMovingBlocks += 1
          let qx = bx >= 2 ? 1 : 0
          let qy = by >= 2 ? 1 : 0
          quadrantActivity[qy * 2 + qx] += 1
        }
      }
    }

    let activeQuadrants = quadrantActivity.filter { $0 >= 1 }.count
    let winActiveQuadrants = winQuadrantActivity.filter { $0 >= 1 }.count

    let stepFlow = evaluateFlowCoherence(dxList: dxList, dyList: dyList, bxList: bxList, byList: byList)
    let winFlow = evaluateFlowCoherence(dxList: winDxList, dyList: winDyList, bxList: winBxList, byList: winByList)
    let coherentTranslatedBlocks = stepFlow.coherentCount
    let loomingRejected = stepFlow.isLooming || (coherentTranslatedBlocks < 5 && winFlow.isLooming)

    var oscillationRejected = false
    let currFlowMag = sqrt((stepFlow.meanDx * stepFlow.meanDx) + (stepFlow.meanDy * stepFlow.meanDy))
    if dxList.count >= 3 && currFlowMag >= 0.30 {
      if hasPrevMeanFlow {
        let prevMag = sqrt((prevMeanFlowDx * prevMeanFlowDx) + (prevMeanFlowDy * prevMeanFlowDy))
        if prevMag >= 0.30 {
          let cosTurn = ((prevMeanFlowDx * stepFlow.meanDx) + (prevMeanFlowDy * stepFlow.meanDy)) / (prevMag * currFlowMag)
          if cosTurn < -0.25 {
            oscillationRejected = true
          }
        }
      }
      prevMeanFlowDx = stepFlow.meanDx
      prevMeanFlowDy = stepFlow.meanDy
      hasPrevMeanFlow = true
    } else if activeMovingBlocks == 0 {
      hasPrevMeanFlow = false
    }

    let fullSceneStructScore = normRefDiffSum / Double(count * 255)
    let meanStepScore = normStepDiffSum / Double(count * 255)
    let texturedStructScore = texturedRefBlocks > 0
      ? (texturedRefScoreSum / Double(texturedRefBlocks))
      : fullSceneStructScore
    let structMotionScore =
      (texturedRefBlocks >= 2 && texturedRefBlocks <= 6 && anchoredTexturedBlocks == 0)
      ? max(fullSceneStructScore, texturedStructScore * 0.80)
      : fullSceneStructScore

    let meanJump = Double(abs(currMean - previousMean255))
    let isLightingTransient = meanJump >= 18.0 && coherentTranslatedBlocks <= 2
    let minAnchors = max(3, Int(ceil(Double(texturedRefBlocks) * 0.22)))
    let minPerimAnchors = max(3, Int(ceil(Double(texturedPerimeterBlocks) * 0.34)))
    let hasStrongStaticAnchors =
      (texturedRefBlocks >= 4 && anchoredTexturedBlocks >= minAnchors)
      || (texturedPerimeterBlocks >= 4 && anchoredPerimeterBlocks >= minPerimAnchors)

    let sparseSceneCoherentEgoMotion =
      texturedRefBlocks >= 2
      && texturedRefBlocks <= 6
      && anchoredTexturedBlocks == 0
      && coherentTranslatedBlocks >= min(3, texturedRefBlocks)
      && stepFlow.rigidCoherence >= 0.58
      && !loomingRejected

    let sparseSceneSlowDrift =
      hasWindowSpan
      && texturedRefBlocks >= 2
      && texturedRefBlocks <= 6
      && anchoredTexturedBlocks == 0
      && winFlow.coherentCount >= min(3, texturedRefBlocks)
      && winFlow.rigidCoherence >= 0.68
      && !winFlow.isLooming

    let fullSceneSlowDrift =
      hasWindowSpan
      && !hasStrongStaticAnchors
      && !isLightingTransient
      && !loomingRejected
      && winFlow.coherentCount >= 5
      && winActiveQuadrants >= 3
      && winFlow.rigidCoherence >= 0.70

    let isScenePresentlyStill =
      coherentTranslatedBlocks == 0
      && !fullSceneSlowDrift
      && !sparseSceneSlowDrift
      && (activeMovingBlocks <= 2 || meanStepScore < 0.009)

    let egoWeight: Double
    if isLightingTransient || isInputDegraded {
      egoWeight = 0.10
    } else if hasStrongStaticAnchors {
      egoWeight = 0.14
    } else if loomingRejected {
      egoWeight = 0.18
    } else if isScenePresentlyStill {
      egoWeight = 0.08
    } else if sparseSceneCoherentEgoMotion {
      egoWeight = 1.20
    } else if coherentTranslatedBlocks >= 5 && activeQuadrants >= 3 && stepFlow.rigidCoherence >= 0.56 {
      egoWeight = 1.25
    } else if activeQuadrants <= 2 && coherentTranslatedBlocks < 5 {
      egoWeight = 0.24
    } else if texturedRefBlocks > 0
      && anchoredPerimeterBlocks == 0
      && anchoredTexturedBlocks == 0
      && activeMovingBlocks >= 12
      && activeQuadrants == 4
      && normalizedDeviation >= 0.028
      && dxList.count >= 3
      && stepFlow.rigidCoherence >= 0.55
    {
      egoWeight = 1.08
    } else if texturedRefBlocks == 0 && activeMovingBlocks >= 13 && activeQuadrants == 4 && meanStepScore >= 0.025 && normalizedDeviation >= 0.015 {
      egoWeight = 0.95
    } else {
      egoWeight = 0.32
    }

    let flowContribution = (!hasStrongStaticAnchors && !loomingRejected && coherentTranslatedBlocks >= 5 && activeQuadrants >= 3 && stepFlow.rigidCoherence >= 0.56)
      ? (Double(coherentTranslatedBlocks) / Double(totalBlocks)) * 0.11 * stepFlow.rigidCoherence
      : (sparseSceneCoherentEgoMotion ? 0.045 : 0.0)
    let fastMotionScore = min(1.0, max(0.0, (structMotionScore * egoWeight) + flowContribution))

    var slowDriftScore = 0.0
    if fullSceneSlowDrift || sparseSceneSlowDrift {
      let driftBonus = (Double(winFlow.coherentCount) / Double(totalBlocks)) * 0.11 * winFlow.rigidCoherence
      slowDriftScore = min(1.0, max(0.0, (structMotionScore * 1.15 * winFlow.rigidCoherence) + driftBonus))
    }

    var motionScore = max(fastMotionScore, slowDriftScore)
    if hasStrongStaticAnchors || loomingRejected {
      motionScore = min(motionScore, motionThreshold * 0.62)
    }
    if oscillationRejected {
      motionScore = min(motionScore, motionThreshold * 0.72)
    }

    let baseAdaptRate: Float = isLightingTransient ? 0.30 : 0.06
    if motionScore >= motionThreshold {
      consecutiveAboveThreshold += 1
      for i in 0..<count {
        referenceGrid[i] = (0.98 * referenceGrid[i]) + (0.02 * currentGrid[i])
        previousGrid[i] = currentGrid[i]
      }
    } else {
      consecutiveAboveThreshold = 0
      for gy in 0..<gridH {
        let by = min(blocksY - 1, (gy * blocksY) / max(1, gridH))
        for gx in 0..<gridW {
          let bx = min(blocksX - 1, (gx * blocksX) / max(1, gridW))
          let bIdx = by * blocksX + bx
          let pxCount = blockPixelCount[bIdx]
          let blockRefScore = pxCount > 0
            ? (blockRefDiffSum[bIdx] / Double(pxCount * 255))
            : 0.0
          let alpha: Float
          if settledBlockStreak[bIdx] >= 4 && isScenePresentlyStill {
            alpha = 0.16
          } else if hasStrongStaticAnchors && blockRefScore >= staticBlockThreshold {
            alpha = 0.01
          } else {
            alpha = baseAdaptRate
          }
          let i = gy * gridW + gx
          referenceGrid[i] = ((1.0 - alpha) * referenceGrid[i]) + (alpha * currentGrid[i])
          previousGrid[i] = currentGrid[i]
        }
      }
    }
    previousMean255 = currMean
    recentGrids.append(currentGrid)
    if recentGrids.count > 4 {
      recentGrids.removeFirst()
    }

    let reportedCoherent = max(
      coherentTranslatedBlocks,
      (fullSceneSlowDrift || sparseSceneSlowDrift) ? winFlow.coherentCount : 0
    )

    if consecutiveAboveThreshold >= persistenceFramesRequired {
      emitEvent([
        "sessionId": sessionId,
        "eventType": "motionTriggered",
        "summary": String(
          format:
            "Sustained camera movement detected (score %.3f ≥ threshold %.3f across %d frames)",
          motionScore,
          motionThreshold,
          consecutiveAboveThreshold
        ),
        "motionScore": motionScore,
        "threshold": motionThreshold,
        "averageLuminance": normalizedLuminance,
        "consecutiveFrames": consecutiveAboveThreshold,
        "coherentBlocks": reportedCoherent,
        "anchoredBlocks": anchoredTexturedBlocks,
        "slowDriftScore": slowDriftScore,
        "loomingRejected": loomingRejected,
        "acPowerUnplugged": acPowerUnpluggedRecently,
        "timestampMs": nowMs,
      ])
    } else if processedFrameCount % 3 == 0 {
      emitEvent([
        "sessionId": sessionId,
        "eventType": "telemetryFrame",
        "summary": String(
          format: "Camera motion score %.3f (threshold %.3f)",
          motionScore,
          motionThreshold
        ),
        "motionScore": motionScore,
        "threshold": motionThreshold,
        "averageLuminance": normalizedLuminance,
        "consecutiveFrames": consecutiveAboveThreshold,
        "coherentBlocks": reportedCoherent,
        "anchoredBlocks": anchoredTexturedBlocks,
        "slowDriftScore": slowDriftScore,
        "loomingRejected": loomingRejected,
        "acPowerUnplugged": acPowerUnpluggedRecently,
        "timestampMs": nowMs,
      ])
    }
  }

  private func evaluateFlowCoherence(
    dxList: [Double],
    dyList: [Double],
    bxList: [Int],
    byList: [Int]
  ) -> (
    coherentCount: Int,
    rigidCoherence: Double,
    meanDx: Double,
    meanDy: Double,
    isLooming: Bool
  ) {
    let n = dxList.count
    if n == 0 {
      return (0, 0.0, 0.0, 0.0, false)
    }
    var sumDx = 0.0
    var sumDy = 0.0
    var sumMag = 0.0
    var cx = 0.0
    var cy = 0.0
    for k in 0..<n {
      sumDx += dxList[k]
      sumDy += dyList[k]
      sumMag += sqrt((dxList[k] * dxList[k]) + (dyList[k] * dyList[k]))
      cx += Double(bxList[k])
      cy += Double(byList[k])
    }
    let meanDx = sumDx / Double(n)
    let meanDy = sumDy / Double(n)
    let meanMag = sumMag / Double(n)
    cx /= Double(n)
    cy /= Double(n)

    let netMag = sqrt((meanDx * meanDx) + (meanDy * meanDy))
    let panCoherence = meanMag > 1e-6 ? min(1.0, max(0.0, netMag / meanMag)) : 0.0

    var panAligned = 0
    var rollPos = 0
    var rollNeg = 0
    var tangentialCosSum = 0.0
    var radialCosSum = 0.0
    var radialSamples = 0

    for k in 0..<n {
      let ux = dxList[k]
      let uy = dyList[k]
      let mag = sqrt((ux * ux) + (uy * uy))
      if mag <= 1e-6 { continue }
      if netMag > 1e-6 {
        let cosPan = ((ux * meanDx) + (uy * meanDy)) / (mag * netMag)
        if cosPan >= 0.45 { panAligned += 1 }
      }
      let ox = Double(bxList[k]) - 1.5
      let oy = Double(byList[k]) - 1.5
      let oRad = sqrt((ox * ox) + (oy * oy))
      let cross = (ox * uy) - (oy * ux)
      if cross > 0.25 {
        rollPos += 1
      } else if cross < -0.25 {
        rollNeg += 1
      }
      if oRad >= 0.45 {
        tangentialCosSum += ((ux * (-oy / oRad)) + (uy * (ox / oRad))) / mag
      }
      let rx = Double(bxList[k]) - cx
      let ry = Double(byList[k]) - cy
      let rRad = sqrt((rx * rx) + (ry * ry))
      if rRad >= 0.45 {
        radialCosSum += ((ux * (rx / rRad)) + (uy * (ry / rRad))) / mag
        radialSamples += 1
      }
    }

    let rollCoherence = min(1.0, max(0.0, abs(tangentialCosSum) / Double(n)))
    let rigidCoherence = max(panCoherence, rollCoherence)
    let radialDivergence = radialSamples >= 3
      ? min(1.0, max(-1.0, radialCosSum / Double(radialSamples)))
      : 0.0
    let coherentCount = max(panAligned, max(rollPos, rollNeg))
    let isLooming = n >= 3 && abs(radialDivergence) >= 0.44 && rigidCoherence < 0.64
    return (coherentCount, rigidCoherence, meanDx, meanDy, isLooming)
  }

  private func estimateLucasKanadeFlow(
    previous: [Float],
    current: [Float],
    gridW: Int,
    gridH: Int,
    stepMeanShift: Double,
    x0: Int,
    y0: Int,
    w: Int,
    h: Int,
    minMagnitude: Double = 0.32
  ) -> (Double, Double)? {
    let startX = max(1, x0)
    let endX = min(gridW - 1, x0 + w)
    let startY = max(1, y0)
    let endY = min(gridH - 1, y0 + h)
    if endX <= startX + 2 || endY <= startY + 2 {
      return nil
    }

    var sxx = 0.0
    var syy = 0.0
    var sxy = 0.0
    var bx = 0.0
    var by = 0.0
    var count = 0

    for y in startY..<endY {
      let row = y * gridW
      let rowUp = (y - 1) * gridW
      let rowDown = (y + 1) * gridW
      for x in startX..<endX {
        let ix = 0.25 * Double(
          (previous[row + x + 1] - previous[row + x - 1])
            + (current[row + x + 1] - current[row + x - 1])
        )
        let iy = 0.25 * Double(
          (previous[rowDown + x] - previous[rowUp + x])
            + (current[rowDown + x] - current[rowUp + x])
        )
        let it = Double(current[row + x] - previous[row + x]) - stepMeanShift

        sxx += ix * ix
        syy += iy * iy
        sxy += ix * iy
        bx -= ix * it
        by -= iy * it
        count += 1
      }
    }

    if count == 0 { return nil }
    let trace = sxx + syy
    let det = (sxx * syy) - (sxy * sxy)
    let disc = max(0.0, (trace * trace) - (4.0 * det))
    let minEigen = 0.5 * (trace - sqrt(disc))
    if det <= 1e-3 || minEigen < Double(count) * 6.0 {
      return nil
    }

    let u = ((syy * bx) - (sxy * by)) / det
    let v = ((-sxy * bx) + (sxx * by)) / det
    let mag = sqrt((u * u) + (v * v))
    if mag < minMagnitude || mag > 3.8 {
      return nil
    }
    return (u, v)
  }

  private func estimateBlockTranslation(
    previous: [Float],
    current: [Float],
    gridW: Int,
    gridH: Int,
    stepMeanShift: Double,
    x0: Int,
    y0: Int,
    w: Int,
    h: Int
  ) -> (Double, Double)? {
    let maxShift = 3
    let startX = max(maxShift, x0 + 1)
    let endX = min(gridW - maxShift, x0 + w - 1)
    let startY = max(maxShift, y0 + 1)
    let endY = min(gridH - maxShift, y0 + h - 1)
    if endX <= startX + 2 || endY <= startY + 2 {
      return nil
    }

    func sadForShift(_ dx: Int, _ dy: Int) -> Double {
      var sad = 0.0
      for y in startY..<endY {
        let prevRow = y * gridW
        let currRow = (y + dy) * gridW
        for x in startX..<endX {
          let prevVal = Double(previous[prevRow + x])
          let currVal = Double(current[currRow + x + dx]) - stepMeanShift
          sad += abs(currVal - prevVal)
        }
      }
      return sad
    }

    let sadZero = sadForShift(0, 0)
    let samplePixels = (endX - startX) * (endY - startY)
    if sadZero / Double(samplePixels) < 2.2 {
      return nil
    }

    var bestSad = sadZero
    var bestDx = 0
    var bestDy = 0
    for dy in -maxShift...maxShift {
      for dx in -maxShift...maxShift where !(dx == 0 && dy == 0) {
        let sad = sadForShift(dx, dy)
        if sad < bestSad {
          bestSad = sad
          bestDx = dx
          bestDy = dy
        }
      }
    }

    if (bestDx != 0 || bestDy != 0) && bestSad < sadZero * 0.84 {
      return (Double(bestDx), Double(bestDy))
    }
    return nil
  }

  private func emitEvent(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }
}

// MARK: - macOS CoreLocation Bridge

final class MacOSLocationBridge: NSObject, CLLocationManagerDelegate {
  private let channel: FlutterMethodChannel
  private let locationManager = CLLocationManager()
  private var pendingAuthCallback: FlutterResult?
  private var pendingLocationCallbacks: [FlutterResult] = []
  private var locationTimeoutWorkItem: DispatchWorkItem?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "dev.watsafe/location",
      binaryMessenger: messenger
    )
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func mapAuthStatus(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .authorizedAlways, .authorized:
      return "granted"
    case .denied, .restricted:
      return "denied"
    case .notDetermined:
      return "notDetermined"
    @unknown default:
      return "notDetermined"
    }
  }

  private func currentAuthStatus() -> CLAuthorizationStatus {
    return locationManager.authorizationStatus
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "checkPermission":
      if !CLLocationManager.locationServicesEnabled() {
        result("denied")
        return
      }
      result(mapAuthStatus(currentAuthStatus()))

    case "requestPermission":
      let status = currentAuthStatus()
      if status != .notDetermined {
        result(mapAuthStatus(status))
        return
      }
      pendingAuthCallback = result
      if #available(macOS 10.15, *) {
        locationManager.requestWhenInUseAuthorization()
      } else {
        locationManager.startUpdatingLocation()
        locationManager.stopUpdatingLocation()
        pendingAuthCallback = nil
        result(mapAuthStatus(currentAuthStatus()))
      }

    case "captureCurrentLocation", "captureLocation":
      guard CLLocationManager.locationServicesEnabled() else {
        result(["status": "unavailable"])
        return
      }
      let status = currentAuthStatus()
      if status == .denied || status == .restricted {
        result(["status": "permissionDenied"])
        return
      }
      let args = call.arguments as? [String: Any]
      let timeoutMs = (args?["timeoutMs"] as? NSNumber)?.intValue ?? 6000
      let highAccuracy = (args?["highAccuracy"] as? Bool) ?? false
      locationManager.desiredAccuracy = highAccuracy
        ? kCLLocationAccuracyNearestTenMeters
        : kCLLocationAccuracyHundredMeters
      pendingLocationCallbacks.append(result)
      if pendingLocationCallbacks.count == 1 {
        let timeoutItem = DispatchWorkItem { [weak self] in
          self?.resolvePendingWithFallbackOrUnavailable()
        }
        locationTimeoutWorkItem = timeoutItem
        DispatchQueue.main.asyncAfter(
          deadline: .now() + .milliseconds(max(1000, timeoutMs)),
          execute: timeoutItem
        )
        if status == .notDetermined {
          if #available(macOS 10.15, *) {
            locationManager.requestWhenInUseAuthorization()
          } else {
            locationManager.requestLocation()
          }
        } else {
          locationManager.requestLocation()
        }
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func isValidLocation(_ loc: CLLocation) -> Bool {
    guard CLLocationCoordinate2DIsValid(loc.coordinate) else {
      return false
    }
    guard loc.horizontalAccuracy >= 0.0, loc.horizontalAccuracy.isFinite else {
      return false
    }
    let lat = loc.coordinate.latitude
    let lon = loc.coordinate.longitude
    guard lat.isFinite, lon.isFinite else {
      return false
    }
    if abs(lat) < 1e-6 && abs(lon) < 1e-6 {
      return false
    }
    return true
  }

  private func serializeLocation(_ loc: CLLocation, isLastKnown: Bool) -> [String: Any] {
    var reducedAccuracy = loc.horizontalAccuracy > 100.0
    if #available(macOS 11.0, *) {
      if locationManager.accuracyAuthorization == .reducedAccuracy {
        reducedAccuracy = true
      }
    }
    return [
      "status": "attached",
      "latitude": loc.coordinate.latitude,
      "longitude": loc.coordinate.longitude,
      "accuracyMeters": loc.horizontalAccuracy,
      "capturedAtMs": Int64(loc.timestamp.timeIntervalSince1970 * 1000.0),
      "isApproximate": reducedAccuracy,
      "isLastKnown": isLastKnown,
    ]
  }

  private func finishPendingLocations(with payload: [String: Any]) {
    locationTimeoutWorkItem?.cancel()
    locationTimeoutWorkItem = nil
    let callbacks = pendingLocationCallbacks
    pendingLocationCallbacks.removeAll()
    for cb in callbacks {
      cb(payload)
    }
  }

  private func resolvePendingWithFallbackOrUnavailable() {
    if let cached = locationManager.location, isValidLocation(cached) {
      finishPendingLocations(with: serializeLocation(cached, isLastKnown: true))
    } else {
      finishPendingLocations(with: ["status": "unavailable"])
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let current = currentAuthStatus()
    if let cb = pendingAuthCallback, current != .notDetermined {
      pendingAuthCallback = nil
      cb(mapAuthStatus(current))
    }
    if !pendingLocationCallbacks.isEmpty {
      if current == .denied || current == .restricted {
        finishPendingLocations(with: ["status": "permissionDenied"])
      } else if current != .notDetermined {
        locationManager.requestLocation()
      }
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let latest = locations.last(where: { isValidLocation($0) }) else {
      resolvePendingWithFallbackOrUnavailable()
      return
    }
    let ageSec = abs(latest.timestamp.timeIntervalSinceNow)
    finishPendingLocations(with: serializeLocation(latest, isLastKnown: ageSec > 120.0))
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    if let clError = error as? CLError, clError.code == .denied {
      finishPendingLocations(with: ["status": "permissionDenied"])
      return
    }
    resolvePendingWithFallbackOrUnavailable()
  }
}

// MARK: - macOS UserNotifications & External URL Bridge

final class MacOSLocalNotificationBridge: NSObject, UNUserNotificationCenterDelegate {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "dev.watsafe/local_notifications",
      binaryMessenger: messenger
    )
    super.init()
    if Bundle.main.bundlePath.hasSuffix(".app") {
      UNUserNotificationCenter.current().delegate = self
    }
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "checkPermission":
      guard Bundle.main.bundlePath.hasSuffix(".app") else {
        result("notApplicable")
        return
      }
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        DispatchQueue.main.async {
          switch settings.authorizationStatus {
          case .authorized, .provisional:
            result("granted")
          case .denied:
            result("denied")
          case .notDetermined:
            result("notDetermined")
          @unknown default:
            result("notDetermined")
          }
        }
      }

    case "requestPermission":
      guard Bundle.main.bundlePath.hasSuffix(".app") else {
        result("notApplicable")
        return
      }
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        DispatchQueue.main.async {
          result(granted ? "granted" : "denied")
        }
      }

    case "showAlertNotification":
      guard Bundle.main.bundlePath.hasSuffix(".app") else {
        result(false)
        return
      }
      let incidentId = (args?["incidentId"] as? String) ?? "inc_alert"
      let deviceName = (args?["deviceName"] as? String) ?? "Protected Device"
      let message = (args?["message"] as? String) ?? "Alarm triggered"
      let isTest = (args?["isTest"] as? Bool) ?? false

      let content = UNMutableNotificationContent()
      content.title = isTest ? "WATSafe Test: \(deviceName)" : "WATSafe Alert: \(deviceName)"
      content.body = message
      content.sound = .default
      content.userInfo = ["incidentId": incidentId]

      let req = UNNotificationRequest(
        identifier: "watsafe_\(incidentId)",
        content: content,
        trigger: nil
      )
      UNUserNotificationCenter.current().add(req) { error in
        DispatchQueue.main.async {
          result(error == nil)
        }
      }

    case "getPushRegistrationToken":
      result(nil)

    case "openExternalUrl":
      guard let rawUrl = args?["url"] as? String,
            let url = URL(string: rawUrl) else {
        result(false)
        return
      }
      result(NSWorkspace.shared.open(url))

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(macOS 11.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let incidentId = response.notification.request.content.userInfo["incidentId"] as? String {
      DispatchQueue.main.async { [weak self] in
        self?.channel.invokeMethod("onNotificationTapped", arguments: ["incidentId": incidentId])
      }
    }
    completionHandler()
  }
}
