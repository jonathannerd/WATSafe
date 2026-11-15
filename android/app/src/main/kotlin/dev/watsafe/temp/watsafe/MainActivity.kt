package dev.watsafe.temp.watsafe

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

class MainActivity : FlutterActivity() {
  private var motionBridge: AndroidMotionSensorBridge? = null
  private var audioBridge: AndroidAudioAlarmBridge? = null
  private var secureStorageBridge: AndroidSecureStorageBridge? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    val messenger = flutterEngine.dartExecutor.binaryMessenger
    motionBridge = AndroidMotionSensorBridge(this, applicationContext, messenger)
    audioBridge = AndroidAudioAlarmBridge(messenger)
    secureStorageBridge = AndroidSecureStorageBridge(applicationContext, messenger)
  }

  override fun onPause() {
    super.onPause()
    motionBridge?.onHostPause()
  }

  override fun onResume() {
    super.onResume()
    motionBridge?.onHostResume()
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray
  ) {
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    motionBridge?.onRequestPermissionsResult(requestCode, grantResults)
  }

  override fun onDestroy() {
    motionBridge?.detachActivity()
    audioBridge?.dispose()
    super.onDestroy()
  }
}

// ============================================================================
// 1. Android 14+ User-Initiated Foreground Monitoring Service & Coordinator
// ============================================================================

class WatSafeForegroundService : Service() {
  companion object {
    const val ACTION_START_MONITORING = "dev.watsafe.action.START_MONITORING"
    const val ACTION_ESCALATE_ALARM = "dev.watsafe.action.ESCALATE_ALARM"
    const val ACTION_STOP_MONITORING = "dev.watsafe.action.STOP_MONITORING"
    const val ACTION_STOP_FROM_NOTIFICATION = "dev.watsafe.action.STOP_FROM_NOTIFICATION"
    const val EXTRA_SENSOR_NAME = "sensor_name"
    const val EXTRA_ALARM_SUMMARY = "alarm_summary"

    private const val MONITOR_CHANNEL_ID = "watsafe_foreground_monitoring"
    private const val ALARM_CHANNEL_ID = "watsafe_alarm_alerts"
    private const val NOTIFICATION_ID = 4201
  }

  override fun onCreate() {
    super.onCreate()
    ensureNotificationChannels()
  }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_STOP_FROM_NOTIFICATION -> {
        cancelVibration()
        WatSafeMonitoringCoordinator.stopFromForegroundService(
          applicationContext,
          "Android foreground monitoring stopped from persistent notification."
        )
        stopForegroundCompat()
        stopSelf()
        return START_NOT_STICKY
      }

      ACTION_STOP_MONITORING -> {
        cancelVibration()
        stopForegroundCompat()
        stopSelf()
        return START_NOT_STICKY
      }

      ACTION_ESCALATE_ALARM -> {
        val summary = intent.getStringExtra(EXTRA_ALARM_SUMMARY)
          ?: "Sustained device motion detected. Open WATSafe and enter your PIN to disarm."
        val notification = buildMonitoringNotification(
          title = "WATSafe ALARM ACTIVE — Enter PIN to Disarm",
          body = summary,
          isAlarm = true
        )
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        nm?.notify(NOTIFICATION_ID, notification)
        triggerAlarmVibration()
        return START_STICKY
      }

      else -> {
        val sensorName = intent?.getStringExtra(EXTRA_SENSOR_NAME)
          ?: WatSafeMonitoringCoordinator.activeSensorName
          ?: "Motion Sensors"
        val isAlarm = WatSafeMonitoringCoordinator.isAlarmLatched
        val notification = buildMonitoringNotification(
          title = if (isAlarm) {
            "WATSafe ALARM ACTIVE — Enter PIN to Disarm"
          } else {
            "WATSafe Armed — Monitoring Device Motion"
          },
          body = if (isAlarm) {
            "Sustained motion detected. Open WATSafe and enter your PIN to disarm."
          } else {
            "Active foreground sensor: $sensorName. Motion monitoring continues while backgrounded."
          },
          isAlarm = isAlarm
        )
        return try {
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
              NOTIFICATION_ID,
              notification,
              ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
          } else {
            startForeground(NOTIFICATION_ID, notification)
          }
          WatSafeMonitoringCoordinator.markForegroundServiceRunning(applicationContext, true)
          START_STICKY
        } catch (error: Exception) {
          WatSafeMonitoringCoordinator.stopFromForegroundService(
            applicationContext,
            "Android 14+ foreground service failed to start: ${error.message ?: "Restricted by OS"}"
          )
          stopSelf()
          START_NOT_STICKY
        }
      }
    }
  }

  override fun onDestroy() {
    cancelVibration()
    WatSafeMonitoringCoordinator.onServiceDestroyed(applicationContext)
    super.onDestroy()
  }

  private fun stopForegroundCompat() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      stopForeground(STOP_FOREGROUND_REMOVE)
    } else {
      @Suppress("DEPRECATION")
      stopForeground(true)
    }
  }

  private fun ensureNotificationChannels() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
      val monitorChannel = NotificationChannel(
        MONITOR_CHANNEL_ID,
        "WATSafe Active Protection",
        NotificationManager.IMPORTANCE_LOW
      ).apply {
        description = "Persistent status notification while WATSafe is armed and monitoring motion."
        setShowBadge(false)
      }
      val alarmChannel = NotificationChannel(
        ALARM_CHANNEL_ID,
        "WATSafe Theft & Tamper Alarms",
        NotificationManager.IMPORTANCE_HIGH
      ).apply {
        description = "High-priority alerts when WATSafe detects unauthorized device movement."
        enableVibration(true)
      }
      nm.createNotificationChannel(monitorChannel)
      nm.createNotificationChannel(alarmChannel)
    }
  }

  private fun buildMonitoringNotification(
    title: String,
    body: String,
    isAlarm: Boolean
  ): Notification {
    ensureNotificationChannels()
    val launchIntent = Intent(this, MainActivity::class.java).apply {
      flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
    }
    val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
      (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
    val openPendingIntent = PendingIntent.getActivity(this, 1001, launchIntent, pendingFlags)

    val stopIntent = Intent(this, WatSafeForegroundService::class.java).apply {
      action = ACTION_STOP_FROM_NOTIFICATION
    }
    val stopPendingIntent = PendingIntent.getService(this, 1002, stopIntent, pendingFlags)

    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      Notification.Builder(this, if (isAlarm) ALARM_CHANNEL_ID else MONITOR_CHANNEL_ID)
    } else {
      @Suppress("DEPRECATION")
      Notification.Builder(this)
    }

    builder
      .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
      .setContentTitle(title)
      .setContentText(body)
      .setContentIntent(openPendingIntent)
      .setOngoing(true)

    if (!isAlarm) {
      val stopAction = Notification.Action.Builder(
        android.R.drawable.ic_media_pause,
        "Stop Monitoring",
        stopPendingIntent
      ).build()
      builder.addAction(stopAction)
    }

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
    }
    return builder.build()
  }

  private fun triggerAlarmVibration() {
    try {
      val vibrator = getVibrator() ?: return
      val timings = longArrayOf(0, 500, 250, 500, 250, 500)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        vibrator.vibrate(VibrationEffect.createWaveform(timings, 0))
      } else {
        @Suppress("DEPRECATION")
        vibrator.vibrate(timings, 0)
      }
    } catch (_: Exception) {}
  }

  private fun cancelVibration() {
    try {
      getVibrator()?.cancel()
    } catch (_: Exception) {}
  }

  private fun getVibrator(): Vibrator? {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
      vm?.defaultVibrator
    } else {
      @Suppress("DEPRECATION")
      getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }
  }
}

private object WatSafeMonitoringCoordinator : SensorEventListener {
  private val mainHandler = Handler(Looper.getMainLooper())
  private var eventSink: EventChannel.EventSink? = null
  private var pendingFailureEvent: Map<String, Any>? = null

  private var appContext: Context? = null
  private var sensorManager: SensorManager? = null
  private var sensorThread: HandlerThread? = null
  private var sensorHandler: Handler? = null
  private var wakeLock: PowerManager.WakeLock? = null
  private var activeSensor: Sensor? = null
  private var usingRawAccelerometer: Boolean = false

  var activeSessionId: String? = null
    private set
  val activeSensorName: String?
    get() = activeSensor?.name
  var isForegroundServiceRunning: Boolean = false
    private set
  var isAlarmLatched: Boolean = false
    private set
  private var stoppingIntentionally: Boolean = false

  private var motionThreshold: Double = 0.095
  private var calibrationDurationMs: Long = 2000L
  private var persistenceFramesRequired: Int = 3
  private var sessionStartTimeMs: Long = 0L
  private var isCalibrationDone: Boolean = false
  private var hasBaseline: Boolean = false
  private var gravityX: Double = 0.0
  private var gravityY: Double = 0.0
  private var gravityZ: Double = 0.0
  private var refX: Double = 0.0
  private var refY: Double = 0.0
  private var refZ: Double = 0.0
  private var refMag: Double = 0.0
  private var consecutiveAboveThreshold: Int = 0
  private var sampleCount: Int = 0

  fun attachEventSink(sink: EventChannel.EventSink?) {
    eventSink = sink
    if (sink != null) {
      val pending = pendingFailureEvent
      if (pending != null) {
        pendingFailureEvent = null
        mainHandler.post { sink.success(pending) }
      }
    }
  }

  fun discoverMotionSensor(context: Context): Sensor? {
    val mgr = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager ?: return null
    sensorManager = mgr
    return mgr.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
      ?: mgr.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
  }

  fun updateThreshold(threshold: Double) {
    motionThreshold = max(0.02, min(0.50, threshold))
  }

  fun startMonitoring(context: Context, args: Map<*, *>): Map<String, Any> {
    stopMonitoringByClient(context)
    val appCtx = context.applicationContext
    appContext = appCtx
    val sensor = discoverMotionSensor(appCtx)
    val mgr = sensorManager
    if (sensor == null || mgr == null) {
      return mapOf(
        "started" to false,
        "message" to "No Android accelerometer or linear acceleration sensor detected.",
        "errorCode" to "NO_SENSOR_HARDWARE"
      )
    }

    val sessionId = (args["sessionId"] as? String) ?: "session_default"
    val threshold = (args["motionScoreThreshold"] as? Number)?.toDouble() ?: 0.095
    val requestedCalibrationMs = (args["calibrationDurationMs"] as? Number)?.toLong() ?: 2000L
    val persistenceFrames = (args["persistenceFramesRequired"] as? Number)?.toInt() ?: 3

    stoppingIntentionally = false
    isAlarmLatched = false
    activeSessionId = sessionId
    activeSensor = sensor
    usingRawAccelerometer = (sensor.type == Sensor.TYPE_ACCELEROMETER)
    motionThreshold = max(0.02, min(0.50, threshold))
    calibrationDurationMs = max(1500L, requestedCalibrationMs)
    persistenceFramesRequired = max(1, persistenceFrames)
    sessionStartTimeMs = System.currentTimeMillis()
    isCalibrationDone = false
    hasBaseline = false
    gravityX = 0.0
    gravityY = 0.0
    gravityZ = 0.0
    consecutiveAboveThreshold = 0
    sampleCount = 0

    val thread = HandlerThread("WatSafeAndroidSensorThread").apply { start() }
    val handler = Handler(thread.looper)
    sensorThread = thread
    sensorHandler = handler

    acquireWakeLock(appCtx)

    val registered = mgr.registerListener(
      this,
      sensor,
      SensorManager.SENSOR_DELAY_GAME,
      handler
    )
    if (!registered) {
      cleanupSensorThreadAndLock()
      activeSessionId = null
      activeSensor = null
      return mapOf(
        "started" to false,
        "message" to "Failed to register Android SensorEventListener.",
        "errorCode" to "REGISTER_LISTENER_FAILED"
      )
    }

    try {
      val serviceIntent = Intent(appCtx, WatSafeForegroundService::class.java).apply {
        action = WatSafeForegroundService.ACTION_START_MONITORING
        putExtra(WatSafeForegroundService.EXTRA_SENSOR_NAME, sensor.name)
      }
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        appCtx.startForegroundService(serviceIntent)
      } else {
        appCtx.startService(serviceIntent)
      }
      isForegroundServiceRunning = true
    } catch (error: Exception) {
      mgr.unregisterListener(this)
      cleanupSensorThreadAndLock()
      activeSessionId = null
      activeSensor = null
      return mapOf(
        "started" to false,
        "message" to "Android blocked starting the foreground monitoring service: ${error.message ?: "ForegroundServiceStartNotAllowed"}",
        "errorCode" to "FOREGROUND_SERVICE_BLOCKED"
      )
    }

    emitEvent(
      mapOf(
        "sessionId" to sessionId,
        "eventType" to "calibrationStarted",
        "summary" to "Foreground service active. Settling & calibrating baseline on ${sensor.name}...",
        "threshold" to motionThreshold,
        "timestampMs" to sessionStartTimeMs
      )
    )

    return mapOf(
      "started" to true,
      "message" to "Android Foreground Service & ${sensor.name} monitoring active."
    )
  }

  fun markForegroundServiceRunning(context: Context, running: Boolean) {
    appContext = context.applicationContext
    isForegroundServiceRunning = running
  }

  private fun escalateForegroundServiceAlarm(summary: String) {
    val ctx = appContext ?: return
    try {
      val serviceIntent = Intent(ctx, WatSafeForegroundService::class.java).apply {
        action = WatSafeForegroundService.ACTION_ESCALATE_ALARM
        putExtra(WatSafeForegroundService.EXTRA_ALARM_SUMMARY, summary)
      }
      ctx.startService(serviceIntent)
    } catch (_: Exception) {}
  }

  private fun cleanupSensorThreadAndLock() {
    sensorThread?.quitSafely()
    sensorThread = null
    sensorHandler = null
    releaseWakeLock()
  }

  fun stopMonitoringByClient(context: Context) {
    val hadActiveOrRunning = activeSessionId != null || isForegroundServiceRunning || isAlarmLatched
    stoppingIntentionally = true
    isForegroundServiceRunning = false
    isAlarmLatched = false
    sensorManager?.unregisterListener(this)
    cleanupSensorThreadAndLock()
    activeSensor = null
    activeSessionId = null
    consecutiveAboveThreshold = 0
    if (hadActiveOrRunning) {
      val appCtx = context.applicationContext
      try {
        val stopIntent = Intent(appCtx, WatSafeForegroundService::class.java).apply {
          action = WatSafeForegroundService.ACTION_STOP_MONITORING
        }
        appCtx.startService(stopIntent)
      } catch (_: Exception) {
        try {
          appCtx.stopService(Intent(appCtx, WatSafeForegroundService::class.java))
        } catch (_: Exception) {}
      }
    }
  }

  fun stopFromForegroundService(context: Context, reason: String) {
    val sessionId = activeSessionId
    stoppingIntentionally = true
    isForegroundServiceRunning = false
    isAlarmLatched = false
    sensorManager?.unregisterListener(this)
    cleanupSensorThreadAndLock()
    activeSensor = null
    activeSessionId = null
    consecutiveAboveThreshold = 0
    if (sessionId != null) {
      emitFailureEvent(
        mapOf(
          "sessionId" to sessionId,
          "eventType" to "detectorFailed",
          "summary" to reason,
          "errorCode" to "FOREGROUND_SERVICE_STOPPED",
          "timestampMs" to System.currentTimeMillis()
        )
      )
    }
  }

  fun onServiceDestroyed(context: Context) {
    isForegroundServiceRunning = false
    if (!stoppingIntentionally && activeSessionId != null) {
      stopFromForegroundService(
        context,
        "Android terminated the foreground motion monitoring service; protection is no longer armed."
      )
    }
  }

  private fun acquireWakeLock(context: Context) {
    releaseWakeLock()
    try {
      val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
      val lock = pm.newWakeLock(
        PowerManager.PARTIAL_WAKE_LOCK,
        "WATSafe::MotionMonitoringWakeLock"
      ).apply {
        setReferenceCounted(false)
        // Bounded max hold (12 hours) so the wake lock can never leak indefinitely.
        acquire(12L * 60L * 60L * 1000L)
      }
      wakeLock = lock
    } catch (_: Exception) {}
  }

  private fun releaseWakeLock() {
    try {
      if (wakeLock?.isHeld == true) {
        wakeLock?.release()
      }
    } catch (_: Exception) {}
    wakeLock = null
  }

  override fun onSensorChanged(event: SensorEvent?) {
    val sessionId = activeSessionId ?: return
    val values = event?.values ?: return
    if (values.size < 3) return

    var rawX = values[0].toDouble()
    var rawY = values[1].toDouble()
    var rawZ = values[2].toDouble()

    // Apply high-pass gravity filter if using raw TYPE_ACCELEROMETER
    if (usingRawAccelerometer) {
      val alpha = 0.82
      if (sampleCount == 0) {
        gravityX = rawX
        gravityY = rawY
        gravityZ = rawZ
      } else {
        gravityX = alpha * gravityX + (1.0 - alpha) * rawX
        gravityY = alpha * gravityY + (1.0 - alpha) * rawY
        gravityZ = alpha * gravityZ + (1.0 - alpha) * rawZ
      }
      rawX -= gravityX
      rawY -= gravityY
      rawZ -= gravityZ
    }

    // Convert m/s^2 to g-units (1g = 9.80665 m/s^2)
    val ax = rawX / 9.80665
    val ay = rawY / 9.80665
    val az = rawZ / 9.80665
    val mag = sqrt(ax * ax + ay * ay + az * az)
    val nowMs = System.currentTimeMillis()
    sampleCount += 1

    if (!hasBaseline) {
      refX = ax
      refY = ay
      refZ = az
      refMag = mag
      hasBaseline = true
      return
    }

    if (!isCalibrationDone) {
      refX = 0.70 * refX + 0.30 * ax
      refY = 0.70 * refY + 0.30 * ay
      refZ = 0.70 * refZ + 0.30 * az
      refMag = 0.70 * refMag + 0.30 * mag

      if (nowMs - sessionStartTimeMs >= calibrationDurationMs && sampleCount >= 5) {
        isCalibrationDone = true
        emitEvent(
          mapOf(
            "sessionId" to sessionId,
            "eventType" to "calibrationCompleted",
            "summary" to "Android foreground service & motion baseline calibrated. Active monitoring enabled.",
            "motionScore" to 0.0,
            "threshold" to motionThreshold,
            "consecutiveFrames" to 0,
            "timestampMs" to nowMs
          )
        )
      }
      return
    }

    val dx = ax - refX
    val dy = ay - refY
    val dz = az - refZ
    val vecDeltaG = sqrt(dx * dx + dy * dy + dz * dz)
    val magDeltaG = abs(mag - refMag)
    val combinedDeltaG = max(vecDeltaG, magDeltaG)

    refX = 0.96 * refX + 0.04 * ax
    refY = 0.96 * refY + 0.04 * ay
    refZ = 0.96 * refZ + 0.04 * az
    refMag = 0.96 * refMag + 0.04 * mag

    val motionScore = max(0.0, min(1.0, combinedDeltaG / 0.85))
    if (motionScore >= motionThreshold) {
      consecutiveAboveThreshold += 1
    } else {
      consecutiveAboveThreshold = 0
    }

    if (consecutiveAboveThreshold >= persistenceFramesRequired) {
      val summary = String.format(
        "Android motion trigger (score %.3f >= threshold %.3f, %.2fg delta)",
        motionScore,
        motionThreshold,
        combinedDeltaG
      )
      if (!isAlarmLatched) {
        isAlarmLatched = true
        escalateForegroundServiceAlarm(summary)
      }
      emitEvent(
        mapOf(
          "sessionId" to sessionId,
          "eventType" to "motionTriggered",
          "summary" to summary,
          "motionScore" to motionScore,
          "threshold" to motionThreshold,
          "consecutiveFrames" to consecutiveAboveThreshold,
          "timestampMs" to nowMs
        )
      )
    } else if (sampleCount % 4 == 0) {
      emitEvent(
        mapOf(
          "sessionId" to sessionId,
          "eventType" to "telemetryFrame",
          "summary" to String.format(
            "Android foreground motion score %.3f (%.2fg delta)",
            motionScore,
            combinedDeltaG
          ),
          "motionScore" to motionScore,
          "threshold" to motionThreshold,
          "consecutiveFrames" to consecutiveAboveThreshold,
          "timestampMs" to nowMs
        )
      )
    }
  }

  override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

  private fun emitEvent(payload: Map<String, Any>) {
    mainHandler.post {
      eventSink?.success(payload)
    }
  }

  private fun emitFailureEvent(payload: Map<String, Any>) {
    mainHandler.post {
      val sink = eventSink
      if (sink != null) {
        sink.success(payload)
      } else {
        pendingFailureEvent = payload
      }
    }
  }
}

// ============================================================================
// 1b. Android Motion Sensor Bridge (`dev.watsafe/android_motion` & `_events`)
// ============================================================================

private class AndroidMotionSensorBridge(
  private var activity: Activity?,
  private val appContext: Context,
  messenger: io.flutter.plugin.common.BinaryMessenger
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

  companion object {
    private const val REQ_CODE_POST_NOTIFICATIONS = 4210
  }

  private val methodChannel = MethodChannel(messenger, "dev.watsafe/android_motion")
  private val eventChannel = EventChannel(messenger, "dev.watsafe/android_motion_events")
  private var pendingPermissionResult: MethodChannel.Result? = null

  init {
    methodChannel.setMethodCallHandler(this)
    eventChannel.setStreamHandler(this)
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    WatSafeMonitoringCoordinator.attachEventSink(events)
  }

  override fun onCancel(arguments: Any?) {
    WatSafeMonitoringCoordinator.attachEventSink(null)
  }

  private fun notificationPermissionGranted(): Boolean {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
        PackageManager.PERMISSION_GRANTED
    } else {
      true
    }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "checkCapability" -> {
        val sensor = WatSafeMonitoringCoordinator.discoverMotionSensor(appContext)
        val hasHardware = sensor != null
        val isLinear = sensor?.type == Sensor.TYPE_LINEAR_ACCELERATION
        val notifGranted = notificationPermissionGranted()
        result.success(
          mapOf(
            "hasMotionHardware" to hasHardware,
            "deviceName" to (sensor?.name ?: "No Motion Sensor Detected"),
            "permissionStatus" to if (!hasHardware) {
              "notApplicable"
            } else if (notifGranted) {
              "granted"
            } else {
              "notDetermined"
            },
            "notificationPermissionGranted" to notifGranted,
            "notificationPermissionStatus" to if (notifGranted) "granted" else "notDetermined",
            "foregroundServiceSupported" to true,
            "detail" to if (hasHardware) {
              val mode = if (isLinear) {
                "Linear Acceleration"
              } else {
                "Accelerometer + Gravity High-Pass Filter"
              }
              if (notifGranted) {
                "Android SensorManager ($mode on ${sensor?.name}) + Foreground Service ready."
              } else {
                "Android SensorManager ($mode on ${sensor?.name}) ready; grant notification permission so the persistent armed status banner is visible."
              }
            } else {
              "Android SensorManager found no linear acceleration or accelerometer sensors."
            }
          )
        )
      }

      "requestPermission" -> {
        if (WatSafeMonitoringCoordinator.discoverMotionSensor(appContext) == null) {
          result.success("notApplicable")
          return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !notificationPermissionGranted()) {
          val hostActivity = activity
          if (hostActivity != null && pendingPermissionResult == null) {
            pendingPermissionResult = result
            hostActivity.requestPermissions(
              arrayOf(Manifest.permission.POST_NOTIFICATIONS),
              REQ_CODE_POST_NOTIFICATIONS
            )
            return
          }
        }
        result.success(if (notificationPermissionGranted()) "granted" else "denied")
      }

      "startMonitoring" -> {
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
        result.success(WatSafeMonitoringCoordinator.startMonitoring(appContext, args))
      }

      "updateSensitivity" -> {
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
        val threshold = (args["motionScoreThreshold"] as? Number)?.toDouble()
        if (threshold != null) {
          WatSafeMonitoringCoordinator.updateThreshold(threshold)
        }
        result.success(null)
      }

      "stopMonitoring" -> {
        WatSafeMonitoringCoordinator.stopMonitoringByClient(appContext)
        result.success(null)
      }

      else -> result.notImplemented()
    }
  }

  fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
    if (requestCode != REQ_CODE_POST_NOTIFICATIONS) return
    val pending = pendingPermissionResult ?: return
    pendingPermissionResult = null
    val granted = grantResults.isNotEmpty() &&
      grantResults[0] == PackageManager.PERMISSION_GRANTED
    pending.success(if (granted) "granted" else "denied")
  }

  fun onHostPause() {
    // Keep motion monitoring running in the background while the foreground
    // service is active (including when the user locks the screen).
    val sessionId = WatSafeMonitoringCoordinator.activeSessionId ?: return
    if (WatSafeMonitoringCoordinator.isForegroundServiceRunning) {
      return
    }
    // Only if no foreground service is active, report the interruption honestly.
    WatSafeMonitoringCoordinator.stopFromForegroundService(
      appContext,
      "Android activity backgrounded without an active foreground service (session $sessionId)."
    )
  }

  fun onHostResume() {
    // Foreground service continued monitoring seamlessly while backgrounded.
  }

  fun detachActivity() {
    activity = null
    pendingPermissionResult = null
    WatSafeMonitoringCoordinator.attachEventSink(null)
  }
}

// ============================================================================
// 2. Android Native Audio Siren Bridge (`dev.watsafe/audio_alarm`)
// ============================================================================

private class AndroidAudioAlarmBridge(
  messenger: io.flutter.plugin.common.BinaryMessenger
) : MethodChannel.MethodCallHandler {

  private val channel = MethodChannel(messenger, "dev.watsafe/audio_alarm")
  private var audioTrack: AudioTrack? = null
  private var currentVolume: Float = 0.85f

  init {
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
    when (call.method) {
      "startLoopingAlarm", "startTestAlarm" -> {
        val vol = (args["volume"] as? Number)?.toFloat() ?: 0.85f
        val wavBytes = args["wavBytes"] as? ByteArray
        currentVolume = max(0.10f, min(1.00f, vol))
        if (wavBytes != null && wavBytes.size > 44) {
          startPcmLoop(wavBytes, currentVolume)
          result.success(null)
        } else {
          result.error("MISSING_WAV", "Missing or invalid WAV bytes", null)
        }
      }

      "stopAlarm" -> {
        stopPlayback()
        result.success(null)
      }

      "setVolume" -> {
        val vol = (args["volume"] as? Number)?.toFloat() ?: currentVolume
        currentVolume = max(0.10f, min(1.00f, vol))
        audioTrack?.setVolume(currentVolume)
        result.success(null)
      }

      else -> result.notImplemented()
    }
  }

  private fun startPcmLoop(wavBytes: ByteArray, volume: Float) {
    stopPlayback()
    try {
      val header = ByteBuffer.wrap(wavBytes, 0, 44).order(ByteOrder.LITTLE_ENDIAN)
      val channels = header.getShort(22).toInt().coerceAtLeast(1)
      val sampleRate = header.getInt(24).coerceIn(8000, 96000)
      val pcmDataSize = wavBytes.size - 44
      if (pcmDataSize <= 0) return

      val channelMask = if (channels == 1) {
        AudioFormat.CHANNEL_OUT_MONO
      } else {
        AudioFormat.CHANNEL_OUT_STEREO
      }

      val track = AudioTrack.Builder()
        .setAudioAttributes(
          AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        )
        .setAudioFormat(
          AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(sampleRate)
            .setChannelMask(channelMask)
            .build()
        )
        .setBufferSizeInBytes(pcmDataSize)
        .setTransferMode(AudioTrack.MODE_STATIC)
        .build()

      track.write(wavBytes, 44, pcmDataSize)
      val totalFrames = pcmDataSize / (2 * channels)
      track.setLoopPoints(0, totalFrames, -1)
      track.setVolume(volume)
      track.play()
      audioTrack = track
    } catch (_: Exception) {
      stopPlayback()
    }
  }

  private fun stopPlayback() {
    try {
      audioTrack?.stop()
    } catch (_: Exception) {}
    try {
      audioTrack?.release()
    } catch (_: Exception) {}
    audioTrack = null
  }

  fun dispose() {
    stopPlayback()
  }
}

// ============================================================================
// 3. Android Keystore Secure PIN Storage Bridge (`dev.watsafe/secure_storage`)
// ============================================================================

private class AndroidSecureStorageBridge(
  context: Context,
  messenger: io.flutter.plugin.common.BinaryMessenger
) : MethodChannel.MethodCallHandler {

  private val channel = MethodChannel(messenger, "dev.watsafe/secure_storage")
  private val prefs = context.getSharedPreferences("watsafe_secure_pin_prefs", Context.MODE_PRIVATE)
  private val keyAlias = "dev.watsafe.pin_master_key"

  init {
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "readPinRecord" -> {
        result.success(readEncryptedRecord())
      }

      "writePinRecord" -> {
        val args = call.arguments as? Map<*, *>
        val payload = args?.get("payload") as? String
        if (payload.isNullOrEmpty()) {
          result.error("INVALID_ARGUMENTS", "Missing payload for writePinRecord", null)
          return
        }
        if (writeEncryptedRecord(payload)) {
          result.success("Android Keystore (AES-256-GCM PBKDF2-HMAC-SHA256)")
        } else {
          result.error("KEYSTORE_WRITE_FAILED", "Failed to encrypt PIN record via Android Keystore", null)
        }
      }

      "deletePinRecord" -> {
        prefs.edit().remove("ciphertext").remove("iv").apply()
        result.success(null)
      }

      else -> result.notImplemented()
    }
  }

  private fun getOrCreateSecretKey(): SecretKey {
    val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    val existing = keyStore.getEntry(keyAlias, null) as? KeyStore.SecretKeyEntry
    if (existing != null) {
      return existing.secretKey
    }
    val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
    val spec = KeyGenParameterSpec.Builder(
      keyAlias,
      KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
    )
      .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
      .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
      .setKeySize(256)
      .build()
    keyGenerator.init(spec)
    return keyGenerator.generateKey()
  }

  private fun writeEncryptedRecord(payload: String): Boolean {
    return try {
      val cipher = Cipher.getInstance("AES/GCM/NoPadding")
      cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
      val ciphertext = cipher.doFinal(payload.toByteArray(Charsets.UTF_8))
      val iv = cipher.iv
      prefs.edit()
        .putString("ciphertext", Base64.encodeToString(ciphertext, Base64.NO_WRAP))
        .putString("iv", Base64.encodeToString(iv, Base64.NO_WRAP))
        .apply()
      true
    } catch (_: Exception) {
      false
    }
  }

  private fun readEncryptedRecord(): String? {
    return try {
      val cipherB64 = prefs.getString("ciphertext", null) ?: return null
      val ivB64 = prefs.getString("iv", null) ?: return null
      val ciphertext = Base64.decode(cipherB64, Base64.NO_WRAP)
      val iv = Base64.decode(ivB64, Base64.NO_WRAP)
      val cipher = Cipher.getInstance("AES/GCM/NoPadding")
      cipher.init(Cipher.DECRYPT_MODE, getOrCreateSecretKey(), GCMParameterSpec(128, iv))
      val plainBytes = cipher.doFinal(ciphertext)
      String(plainBytes, Charsets.UTF_8)
    } catch (_: Exception) {
      null
    }
  }
}
