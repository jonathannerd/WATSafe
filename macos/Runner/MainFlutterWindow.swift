import AVFoundation
import Cocoa
import FlutterMacOS
import Security

class MainFlutterWindow: NSWindow {
  private var cameraBridge: MacOSCameraMotionBridge?
  private var audioBridge: MacOSAudioAlarmBridge?
  private var secureStorageBridge: MacOSSecureStorageBridge?

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
      if let keychainValue = readFromKeychain() {
        result(keychainValue)
        return
      }
      result(readFromProtectedFile())

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
      let keychainOk = writeToKeychain(payload: payload)
      writeToProtectedFile(payload: payload)
      if keychainOk {
        result("macOS Security Keychain (PBKDF2-HMAC-SHA256)")
      } else {
        result("macOS Sandboxed Application Support (0600 PBKDF2-HMAC-SHA256)")
      }

    case "deletePinRecord":
      deleteFromKeychain()
      deleteProtectedFile()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func readFromKeychain() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: accountName,
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

  private func writeToKeychain(payload: String) -> Bool {
    guard let data = payload.data(using: .utf8) else {
      return false
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: accountName,
    ]
    SecItemDelete(query as CFDictionary)

    var attributes = query
    attributes[kSecValueData as String] = data
    let status = SecItemAdd(attributes as CFDictionary, nil)
    return status == errSecSuccess
  }

  private func deleteFromKeychain() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: accountName,
    ]
    SecItemDelete(query as CFDictionary)
  }

  private func protectedFileURL() -> URL? {
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
    return dir.appendingPathComponent("secure_pin_record.json")
  }

  private func readFromProtectedFile() -> String? {
    guard let url = protectedFileURL(),
      FileManager.default.fileExists(atPath: url.path)
    else {
      return nil
    }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  private func writeToProtectedFile(payload: String) {
    guard let url = protectedFileURL() else {
      return
    }
    try? payload.write(to: url, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
  }

  private func deleteProtectedFile() {
    guard let url = protectedFileURL() else {
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
  private var motionThreshold: Double = 0.095
  private var calibrationDurationMs: Int = 1500
  private var persistenceFramesRequired: Int = 3
  private var downsampleWidth: Int = 64
  private var downsampleHeight: Int = 48

  private var sessionStartTimeMs: Int64 = 0
  private var isCalibrationDone: Bool = false
  private var referenceGrid: [Float] = []
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
      guard let self = self, let sessionId = self.activeSessionId else { return }
      self.emitEvent([
        "sessionId": sessionId,
        "eventType": "lifecyclePaused",
        "summary": "macOS system entering sleep; webcam capture paused.",
        "timestampMs": Int64(Date().timeIntervalSince1970 * 1000),
      ])
    }

    wakeObserver = center.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, let sessionId = self.activeSessionId else { return }
      self.emitEvent([
        "sessionId": sessionId,
        "eventType": "lifecycleResumed",
        "summary": "macOS system woke from sleep; webcam monitoring resumed.",
        "timestampMs": Int64(Date().timeIntervalSince1970 * 1000),
      ])
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
      result([
        "started": false,
        "message": "Camera permission is not granted (\(permissionStatusString(authStatus))).",
        "errorCode": "PERMISSION_NOT_GRANTED",
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

    processingQueue.async { [weak self] in
      guard let self = self else { return }
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
          DispatchQueue.main.async {
            result([
              "started": false,
              "message": "Cannot attach camera device input to AVCaptureSession.",
              "errorCode": "INPUT_ATTACH_FAILED",
            ])
          }
          return
        }
        session.addInput(input)
      } catch {
        session.commitConfiguration()
        DispatchQueue.main.async {
          result([
            "started": false,
            "message": "Failed to open camera input: \(error.localizedDescription)",
            "errorCode": "INPUT_OPEN_ERROR",
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
      self.motionThreshold = max(0.02, min(0.50, threshold))
      self.calibrationDurationMs = max(500, calibrationMs)
      self.persistenceFramesRequired = max(1, persistenceFrames)
      self.downsampleWidth = max(16, min(160, width))
      self.downsampleHeight = max(12, min(120, height))
      self.sessionStartTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
      self.isCalibrationDone = false
      self.referenceGrid = []
      self.consecutiveAboveThreshold = 0
      self.consecutivePoorInputFrames = 0
      self.isInputDegraded = false
      self.processedFrameCount = 0
      self.lastFrameProcessedTime = 0

      self.runtimeErrorObserver = NotificationCenter.default.addObserver(
        forName: .AVCaptureSessionRuntimeError,
        object: session,
        queue: .main
      ) { [weak self] notification in
        guard let self = self, let activeId = self.activeSessionId else { return }
        let errorObj = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        self.emitEvent([
          "sessionId": activeId,
          "eventType": "detectorFailed",
          "summary":
            "Camera capture runtime error: \(errorObj?.localizedDescription ?? "Unknown AVFoundation error")",
          "errorCode": "AVCAPTURE_RUNTIME_ERROR",
          "timestampMs": Int64(Date().timeIntervalSince1970 * 1000),
        ])
      }

      self.captureSession = session
      session.startRunning()

      guard session.isRunning else {
        self.stopCaptureOnQueue()
        DispatchQueue.main.async {
          result([
            "started": false,
            "message": "AVCaptureSession failed to enter running state.",
            "errorCode": "SESSION_NOT_RUNNING",
          ])
        }
        return
      }

      self.emitEvent([
        "sessionId": sessionId,
        "eventType": "calibrationStarted",
        "summary": "Calibrating baseline scene on \(device.localizedName)...",
        "threshold": self.motionThreshold,
        "timestampMs": Int64(Date().timeIntervalSince1970 * 1000),
      ])

      DispatchQueue.main.async {
        result([
          "started": true,
          "message": "Monitoring active on \(device.localizedName).",
        ])
      }
    }
  }

  private func stopCaptureOnQueue() {
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
    referenceGrid = []
    consecutiveAboveThreshold = 0
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let sessionId = activeSessionId else { return }

    let now = CFAbsoluteTimeGetCurrent()
    // Process ~8 frames per second off the UI thread.
    if now - lastFrameProcessedTime < 0.12 {
      return
    }
    lastFrameProcessedTime = now

    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }

    let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
    let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard
      srcWidth > 0,
      srcHeight > 0,
      let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
    else {
      return
    }

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
        let pixelOffset = rowOffset + (sx * 4)
        let b = Int(ptr[pixelOffset])
        let g = Int(ptr[pixelOffset + 1])
        let r = Int(ptr[pixelOffset + 2])
        let y = Float((77 * r + 150 * g + 29 * b) >> 8)
        let idx = gy * gridW + gx
        currentGrid[idx] = y
        lumSum += y
      }
    }

    let meanLum255 = lumSum / Float(count)
    let normalizedLuminance = Double(meanLum255 / 255.0)

    var varianceSum: Float = 0
    for val in currentGrid {
      varianceSum += abs(val - meanLum255)
    }
    let normalizedDeviation = Double((varianceSum / Float(count)) / 255.0)

    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
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
    if referenceGrid.count != count {
      referenceGrid = currentGrid
      return
    }

    let elapsedMs = nowMs - sessionStartTimeMs
    if !isCalibrationDone {
      for i in 0..<count {
        referenceGrid[i] = (0.65 * referenceGrid[i]) + (0.35 * currentGrid[i])
      }
      if elapsedMs >= Int64(calibrationDurationMs) && processedFrameCount >= 4 {
        isCalibrationDone = true
        emitEvent([
          "sessionId": sessionId,
          "eventType": "calibrationCompleted",
          "summary": "Scene baseline calibrated. Active scene-motion filtering enabled.",
          "motionScore": 0.0,
          "threshold": motionThreshold,
          "averageLuminance": normalizedLuminance,
          "consecutiveFrames": 0,
          "timestampMs": nowMs,
        ])
      }
      return
    }

    // Compute normalized scene-motion score in [0.0, 1.0]
    var diffSum: Float = 0
    for i in 0..<count {
      let delta = abs(currentGrid[i] - referenceGrid[i])
      diffSum += delta
      // Exponentially adapt reference frame to gradual ambient lighting shifts
      referenceGrid[i] = (0.92 * referenceGrid[i]) + (0.08 * currentGrid[i])
    }

    let motionScore = Double(diffSum / Float(count * 255))
    if motionScore >= motionThreshold {
      consecutiveAboveThreshold += 1
    } else {
      consecutiveAboveThreshold = 0
    }

    if consecutiveAboveThreshold >= persistenceFramesRequired {
      emitEvent([
        "sessionId": sessionId,
        "eventType": "motionTriggered",
        "summary": String(
          format:
            "Sustained scene motion detected (score %.3f ≥ threshold %.3f across %d frames)",
          motionScore,
          motionThreshold,
          consecutiveAboveThreshold
        ),
        "motionScore": motionScore,
        "threshold": motionThreshold,
        "averageLuminance": normalizedLuminance,
        "consecutiveFrames": consecutiveAboveThreshold,
        "timestampMs": nowMs,
      ])
    } else if processedFrameCount % 3 == 0 {
      emitEvent([
        "sessionId": sessionId,
        "eventType": "telemetryFrame",
        "summary": String(
          format: "Scene motion score %.3f (threshold %.3f)",
          motionScore,
          motionThreshold
        ),
        "motionScore": motionScore,
        "threshold": motionThreshold,
        "averageLuminance": normalizedLuminance,
        "consecutiveFrames": consecutiveAboveThreshold,
        "timestampMs": nowMs,
      ])
    }
  }

  private func emitEvent(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }
}
