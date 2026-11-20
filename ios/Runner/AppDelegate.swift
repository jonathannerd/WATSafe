import AVFoundation
import CoreLocation
import CoreMotion
import Flutter
import Security
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var motionBridge: IOSCoreMotionBridge?
  private var audioBridge: IOSAudioAlarmBridge?
  private var secureStorageBridge: IOSSecureStorageBridge?
  private var locationBridge: IOSLocationBridge?
  private var notificationBridge: IOSLocalNotificationBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    motionBridge = IOSCoreMotionBridge(messenger: messenger)
    audioBridge = IOSAudioAlarmBridge(messenger: messenger)
    secureStorageBridge = IOSSecureStorageBridge(messenger: messenger)
    locationBridge = IOSLocationBridge(messenger: messenger)
    notificationBridge = IOSLocalNotificationBridge(messenger: messenger)
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hexToken = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    notificationBridge?.updateApnsDeviceToken(hexToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let incidentId = response.notification.request.content.userInfo["incidentId"] as? String {
      notificationBridge?.emitNotificationTap(incidentId)
    }
    completionHandler()
  }
}

// MARK: - 1. iOS Core Motion Foreground Bridge (`dev.watsafe/ios_motion` & `_events`)

final class IOSCoreMotionBridge: NSObject, FlutterStreamHandler {
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private let motionManager = CMMotionManager()
  private let motionQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "dev.watsafe.ios.coremotion"
    queue.maxConcurrentOperationCount = 1
    return queue
  }()

  private var eventSink: FlutterEventSink?
  private var activeSessionId: String?
  private var motionThreshold: Double = 0.095
  private var calibrationDurationMs: Int64 = 1500
  private var persistenceFramesRequired: Int = 3

  private var sessionStartTimeMs: Int64 = 0
  private var isCalibrationDone: Bool = false
  private var hasBaseline: Bool = false
  private var refX: Double = 0.0
  private var refY: Double = 0.0
  private var refZ: Double = 0.0
  private var refMag: Double = 0.0
  private var consecutiveAboveThreshold: Int = 0
  private var sampleCount: Int = 0

  private var pausedSessionId: String?
  private var resignActiveObserver: NSObjectProtocol?
  private var becomeActiveObserver: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "dev.watsafe/ios_motion",
      binaryMessenger: messenger
    )
    eventChannel = FlutterEventChannel(
      name: "dev.watsafe/ios_motion_events",
      binaryMessenger: messenger
    )
    super.init()

    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call: call, result: result)
    }
    eventChannel.setStreamHandler(self)
    registerLifecycleObservers()
  }

  deinit {
    if let obs = resignActiveObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    if let obs = becomeActiveObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    stopUpdates()
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

  private func registerLifecycleObservers() {
    resignActiveObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, let sessionId = self.activeSessionId else { return }
      self.pausedSessionId = sessionId
      self.stopUpdates()
      self.emitEvent([
        "sessionId": sessionId,
        "eventType": "lifecyclePaused",
        "summary": "iOS app entered background or screen locked; Core Motion monitoring paused.",
        "timestampMs": Int64(Date().timeIntervalSince1970 * 1000),
      ])
    }

    becomeActiveObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, let sessionId = self.pausedSessionId ?? self.activeSessionId else {
        return
      }
      self.pausedSessionId = nil
      self.emitEvent([
        "sessionId": sessionId,
        "eventType": "lifecycleResumed",
        "summary": "iOS app returned to foreground; resuming Core Motion monitoring.",
        "timestampMs": Int64(Date().timeIntervalSince1970 * 1000),
      ])
    }
  }

  private func hasMotionHardware() -> Bool {
    return motionManager.isDeviceMotionAvailable || motionManager.isAccelerometerAvailable
  }

  /// CMMotionManager exposes an explicit authorization status starting in
  /// iOS/iPadOS 27.2. Earlier supported releases do not expose an equivalent
  /// status for this live-sensor API, so report notApplicable rather than
  /// incorrectly claiming that permission was granted.
  private func motionPermissionStatus() -> String {
    if #available(iOS 27.2, *) {
      switch CMMotionManager.authorizationStatus {
      case .notDetermined:
        return "notDetermined"
      case .restricted:
        return "restricted"
      case .denied:
        return "denied"
      case .authorized:
        return "granted"
      @unknown default:
        return "notDetermined"
      }
    }
    return "notApplicable"
  }

  /// Starting a short-lived sensor stream is what allows iOS to present its
  /// motion-access prompt when authorization is not yet determined.
  private func requestMotionPermission(result: @escaping FlutterResult) {
    var completed = false
    let finish: (Bool) -> Void = { [weak self] receivedSample in
      guard let self = self, !completed else { return }
      completed = true
      self.motionManager.stopAccelerometerUpdates()
      let status = self.motionPermissionStatus()
      // A delivered sensor sample is definitive proof of access even if the
      // OS authorization snapshot has not refreshed yet.
      result(status == "notDetermined" && receivedSample ? "granted" : status)
    }

    motionManager.accelerometerUpdateInterval = 0.10
    motionManager.startAccelerometerUpdates(to: .main) { data, error in
      if data != nil {
        finish(true)
      } else if error != nil {
        finish(false)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      finish(false)
    }
  }

  private func handleMethodCall(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "checkCapability":
      let available = hasMotionHardware()
      let permission = motionPermissionStatus()
      result([
        "hasMotionHardware": available,
        "deviceName": available ? "Apple Core Motion IMU" : "No Core Motion Hardware",
        "permissionStatus": available ? permission : "notApplicable",
        "detail": !available
          ? "CMMotionManager reported no device motion or accelerometer hardware."
          : (permission == "notApplicable"
              ? "Foreground Core Motion is available. This iOS version does not expose a separate live-sensor authorization status."
              : "Foreground Core Motion availability and authorization: \(permission)."),
      ])

    case "requestPermission":
      guard hasMotionHardware() else {
        result("notApplicable")
        return
      }
      if #available(iOS 27.2, *) {
        switch CMMotionManager.authorizationStatus {
        case .notDetermined:
          requestMotionPermission(result: result)
        case .restricted:
          result("restricted")
        case .denied:
          result("denied")
        case .authorized:
          result("granted")
        @unknown default:
          result("notDetermined")
        }
      } else {
        // No separate live-sensor permission status exists on earlier iOS.
        // Actual sensor availability is checked when monitoring starts.
        result("notApplicable")
      }

    case "startMonitoring":
      let args = call.arguments as? [String: Any] ?? [:]
      startMonitoring(args: args, result: result)

    case "updateSensitivity":
      let args = call.arguments as? [String: Any] ?? [:]
      if let threshold = (args["motionScoreThreshold"] as? NSNumber)?.doubleValue {
        motionQueue.addOperation { [weak self] in
          self?.motionThreshold = max(0.02, min(0.50, threshold))
        }
      }
      result(nil)

    case "stopMonitoring":
      stopUpdates()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startMonitoring(
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    stopUpdates()
    guard hasMotionHardware() else {
      result([
        "started": false,
        "message": "No iOS Core Motion hardware detected.",
        "errorCode": "NO_MOTION_HARDWARE",
      ])
      return
    }
    if #available(iOS 27.2, *),
      CMMotionManager.authorizationStatus != .authorized
    {
      result([
        "started": false,
        "message": "Allow WATSafe to access motion data before arming protection.",
        "errorCode": "MOTION_PERMISSION_REQUIRED",
        "permissionStatus": motionPermissionStatus(),
      ])
      return
    }

    let sessionId = (args["sessionId"] as? String) ?? "session_default"
    let threshold = (args["motionScoreThreshold"] as? NSNumber)?.doubleValue ?? 0.095
    let calibrationMs = (args["calibrationDurationMs"] as? NSNumber)?.int64Value ?? 1500
    let persistenceFrames = (args["persistenceFramesRequired"] as? NSNumber)?.intValue ?? 3

    activeSessionId = sessionId
    motionThreshold = max(0.02, min(0.50, threshold))
    calibrationDurationMs = max(400, calibrationMs)
    persistenceFramesRequired = max(1, persistenceFrames)
    sessionStartTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
    isCalibrationDone = false
    hasBaseline = false
    consecutiveAboveThreshold = 0
    sampleCount = 0

    let intervalSeconds = 0.04
    if motionManager.isDeviceMotionAvailable {
      motionManager.deviceMotionUpdateInterval = intervalSeconds
      motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
        guard let self = self, let m = motion else { return }
        let ax = m.gravity.x + m.userAcceleration.x
        let ay = m.gravity.y + m.userAcceleration.y
        let az = m.gravity.z + m.userAcceleration.z
        self.processAccelerationSample(ax: ax, ay: ay, az: az)
      }
    } else if motionManager.isAccelerometerAvailable {
      motionManager.accelerometerUpdateInterval = intervalSeconds
      motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, _ in
        guard let self = self, let a = data?.acceleration else { return }
        self.processAccelerationSample(ax: a.x, ay: a.y, az: a.z)
      }
    }

    emitEvent([
      "sessionId": sessionId,
      "eventType": "calibrationStarted",
      "summary": "Calibrating baseline on Apple Core Motion IMU...",
      "threshold": motionThreshold,
      "timestampMs": sessionStartTimeMs,
    ])

    result([
      "started": true,
      "message": "Foreground Core Motion monitoring active.",
    ])
  }

  private func processAccelerationSample(ax: Double, ay: Double, az: Double) {
    guard let sessionId = activeSessionId else { return }
    sampleCount += 1
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let mag = sqrt(ax * ax + ay * ay + az * az)

    if !hasBaseline {
      refX = ax
      refY = ay
      refZ = az
      refMag = mag
      hasBaseline = true
      return
    }

    if !isCalibrationDone {
      refX = 0.70 * refX + 0.30 * ax
      refY = 0.70 * refY + 0.30 * ay
      refZ = 0.70 * refZ + 0.30 * az
      refMag = 0.70 * refMag + 0.30 * mag

      if (nowMs - sessionStartTimeMs) >= calibrationDurationMs && sampleCount >= 5 {
        isCalibrationDone = true
        emitEvent([
          "sessionId": sessionId,
          "eventType": "calibrationCompleted",
          "summary": "iOS Core Motion baseline calibrated. Active motion detection enabled.",
          "motionScore": 0.0,
          "threshold": motionThreshold,
          "consecutiveFrames": 0,
          "timestampMs": nowMs,
        ])
      }
      return
    }

    let dx = ax - refX
    let dy = ay - refY
    let dz = az - refZ
    let vecDeltaG = sqrt(dx * dx + dy * dy + dz * dz)
    let magDeltaG = abs(mag - refMag)
    let combinedDeltaG = max(vecDeltaG, magDeltaG)

    refX = 0.96 * refX + 0.04 * ax
    refY = 0.96 * refY + 0.04 * ay
    refZ = 0.96 * refZ + 0.04 * az
    refMag = 0.96 * refMag + 0.04 * mag

    let motionScore = max(0.0, min(1.0, combinedDeltaG / 0.85))
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
          format: "iOS Core Motion trigger (score %.3f ≥ threshold %.3f, %.2fg delta)",
          motionScore,
          motionThreshold,
          combinedDeltaG
        ),
        "motionScore": motionScore,
        "threshold": motionThreshold,
        "consecutiveFrames": consecutiveAboveThreshold,
        "timestampMs": nowMs,
      ])
    } else if sampleCount % 4 == 0 {
      emitEvent([
        "sessionId": sessionId,
        "eventType": "telemetryFrame",
        "summary": String(
          format: "Core Motion score %.3f (%.2fg delta)",
          motionScore,
          combinedDeltaG
        ),
        "motionScore": motionScore,
        "threshold": motionThreshold,
        "consecutiveFrames": consecutiveAboveThreshold,
        "timestampMs": nowMs,
      ])
    }
  }

  private func stopUpdates() {
    if motionManager.isDeviceMotionActive {
      motionManager.stopDeviceMotionUpdates()
    }
    if motionManager.isAccelerometerActive {
      motionManager.stopAccelerometerUpdates()
    }
    activeSessionId = nil
    consecutiveAboveThreshold = 0
  }

  private func emitEvent(_ payload: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }
}

// MARK: - 2. iOS Native Audio Siren Bridge (`dev.watsafe/audio_alarm`)

final class IOSAudioAlarmBridge: NSObject {
  private let channel: FlutterMethodChannel
  private var player: AVAudioPlayer?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "dev.watsafe/audio_alarm",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call: call, result: result)
    }
  }

  private func handleMethodCall(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "startLoopingAlarm", "startTestAlarm":
      let volume = (args["volume"] as? NSNumber)?.floatValue ?? 0.85
      guard let typedData = args["wavBytes"] as? FlutterStandardTypedData else {
        result(
          FlutterError(
            code: "MISSING_WAV",
            message: "No WAV byte payload provided",
            details: nil
          )
        )
        return
      }
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.duckOthers])
        try session.setActive(true)
        player?.stop()
        let audioPlayer = try AVAudioPlayer(data: typedData.data)
        audioPlayer.numberOfLoops = -1
        audioPlayer.volume = max(0.10, min(1.0, volume))
        audioPlayer.prepareToPlay()
        audioPlayer.play()
        player = audioPlayer
        result(nil)
      } catch {
        result(
          FlutterError(
            code: "AUDIO_INIT_FAILED",
            message: error.localizedDescription,
            details: nil
          )
        )
      }

    case "stopAlarm":
      player?.stop()
      player = nil
      result(nil)

    case "setVolume":
      if let volume = (args["volume"] as? NSNumber)?.floatValue {
        player?.volume = max(0.10, min(1.0, volume))
      }
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

// MARK: - 3. iOS Keychain Secure Storage Bridge (`dev.watsafe/secure_storage`)

final class IOSSecureStorageBridge: NSObject {
  private let channel: FlutterMethodChannel
  private let serviceName = "dev.watsafe.security.pin"
  private let accountName = "pbkdf2_pin_record_v1"

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "dev.watsafe/secure_storage",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call: call, result: result)
    }
  }

  private func handleMethodCall(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "readPinRecord":
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: accountName,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecSuccess,
        let data = item as? Data,
        let str = String(data: data, encoding: .utf8)
      {
        result(str)
      } else {
        result(nil)
      }

    case "writePinRecord":
      let args = call.arguments as? [String: Any]
      guard let payload = args?["payload"] as? String,
        let data = payload.data(using: .utf8)
      else {
        result(
          FlutterError(
            code: "INVALID_ARGUMENTS",
            message: "Missing payload for writePinRecord",
            details: nil
          )
        )
        return
      }
      let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: accountName,
      ]
      SecItemDelete(deleteQuery as CFDictionary)

      let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: accountName,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ]
      let status = SecItemAdd(addQuery as CFDictionary, nil)
      if status == errSecSuccess {
        result("iOS Keychain Services (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)")
      } else {
        result(
          FlutterError(
            code: "KEYCHAIN_WRITE_FAILED",
            message: "SecItemAdd failed with status \(status)",
            details: nil
          )
        )
      }

    case "deletePinRecord":
      let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecAttrAccount as String: accountName,
      ]
      SecItemDelete(deleteQuery as CFDictionary)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

// MARK: - 4. iOS CoreLocation Bridge (`dev.watsafe/location`)

final class IOSLocationBridge: NSObject, CLLocationManagerDelegate {
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
    case .authorizedAlways, .authorizedWhenInUse:
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
    if #available(iOS 14.0, *) {
      return locationManager.authorizationStatus
    }
    return CLLocationManager.authorizationStatus()
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
      locationManager.requestWhenInUseAuthorization()

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
          locationManager.requestWhenInUseAuthorization()
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
    if #available(iOS 14.0, *) {
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

// MARK: - 5. iOS UserNotifications, APNs Token & URL Bridge (`dev.watsafe/local_notifications`)

final class IOSLocalNotificationBridge: NSObject {
  private let channel: FlutterMethodChannel
  private var apnsDeviceTokenHex: String?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "dev.watsafe/local_notifications",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  func updateApnsDeviceToken(_ token: String) {
    apnsDeviceTokenHex = token
  }

  func emitNotificationTap(_ incidentId: String) {
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("onNotificationTapped", arguments: ["incidentId": incidentId])
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "checkPermission":
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        DispatchQueue.main.async {
          switch settings.authorizationStatus {
          case .authorized, .provisional, .ephemeral:
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
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        DispatchQueue.main.async {
          if granted {
            UIApplication.shared.registerForRemoteNotifications()
          }
          result(granted ? "granted" : "denied")
        }
      }

    case "showAlertNotification":
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
      result(apnsDeviceTokenHex)

    case "openExternalUrl":
      guard let rawUrl = args?["url"] as? String,
            let url = URL(string: rawUrl) else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in
        result(opened)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
