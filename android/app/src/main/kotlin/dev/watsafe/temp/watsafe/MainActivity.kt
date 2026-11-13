package dev.watsafe.temp.watsafe

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
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
    motionBridge = AndroidMotionSensorBridge(applicationContext, messenger)
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

  override fun onDestroy() {
    motionBridge?.dispose()
    audioBridge?.dispose()
    super.onDestroy()
  }
}

// ============================================================================
// 1. Android Motion Sensor Bridge (`dev.watsafe/android_motion` & `_events`)
// ============================================================================

private class AndroidMotionSensorBridge(
  private val context: Context,
  messenger: io.flutter.plugin.common.BinaryMessenger
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, SensorEventListener {

  private val methodChannel = MethodChannel(messenger, "dev.watsafe/android_motion")
  private val eventChannel = EventChannel(messenger, "dev.watsafe/android_motion_events")
  private val mainHandler = Handler(Looper.getMainLooper())
  private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager

  private var eventSink: EventChannel.EventSink? = null
  private var activeSensor: Sensor? = null
  private var activeSessionId: String? = null
  private var motionThreshold: Double = 0.095
  private var calibrationDurationMs: Long = 1500L
  private var persistenceFramesRequired: Int = 3

  private var sessionStartTimeMs: Long = 0L
  private var isCalibrationDone: Boolean = false
  private var hasBaseline: Boolean = false
  private var refX: Double = 0.0
  private var refY: Double = 0.0
  private var refZ: Double = 0.0
  private var refMag: Double = 0.0
  private var consecutiveAboveThreshold: Int = 0
  private var sampleCount: Int = 0

  init {
    methodChannel.setMethodCallHandler(this)
    eventChannel.setStreamHandler(this)
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  private fun discoverMotionSensor(): Sensor? {
    val mgr = sensorManager ?: return null
    return mgr.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
      ?: mgr.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "checkCapability" -> {
        val sensor = discoverMotionSensor()
        val hasHardware = sensor != null
        result.success(
          mapOf(
            "hasMotionHardware" to hasHardware,
            "deviceName" to (sensor?.name ?: "No Motion Sensor Detected"),
            "permissionStatus" to if (hasHardware) "granted" else "notApplicable",
            "detail" to if (hasHardware) {
              "Android SensorManager ready (${sensor?.name}, vendor: ${sensor?.vendor})."
            } else {
              "Android SensorManager found no linear acceleration or accelerometer sensors."
            }
          )
        )
      }

      "requestPermission" -> {
        result.success(if (discoverMotionSensor() != null) "granted" else "notApplicable")
      }

      "startMonitoring" -> {
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
        startMonitoring(args, result)
      }

      "updateSensitivity" -> {
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
        val threshold = (args["motionScoreThreshold"] as? Number)?.toDouble()
        if (threshold != null) {
          motionThreshold = max(0.02, min(0.50, threshold))
        }
        result.success(null)
      }

      "stopMonitoring" -> {
        stopMonitoringInternal()
        result.success(null)
      }

      else -> result.notImplemented()
    }
  }

  private fun startMonitoring(args: Map<*, *>, result: MethodChannel.Result) {
    stopMonitoringInternal()
    val sensor = discoverMotionSensor()
    if (sensor == null || sensorManager == null) {
      result.success(
        mapOf(
          "started" to false,
          "message" to "No Android accelerometer or linear acceleration sensor detected.",
          "errorCode" to "NO_SENSOR_HARDWARE"
        )
      )
      return
    }

    val sessionId = (args["sessionId"] as? String) ?: "session_default"
    val threshold = (args["motionScoreThreshold"] as? Number)?.toDouble() ?: 0.095
    val calibrationMs = (args["calibrationDurationMs"] as? Number)?.toLong() ?: 1500L
    val persistenceFrames = (args["persistenceFramesRequired"] as? Number)?.toInt() ?: 3

    activeSessionId = sessionId
    activeSensor = sensor
    motionThreshold = max(0.02, min(0.50, threshold))
    calibrationDurationMs = max(400L, calibrationMs)
    persistenceFramesRequired = max(1, persistenceFrames)
    sessionStartTimeMs = System.currentTimeMillis()
    isCalibrationDone = false
    hasBaseline = false
    consecutiveAboveThreshold = 0
    sampleCount = 0

    val registered = sensorManager.registerListener(
      this,
      sensor,
      SensorManager.SENSOR_DELAY_GAME
    )
    if (!registered) {
      activeSessionId = null
      activeSensor = null
      result.success(
        mapOf(
          "started" to false,
          "message" to "Failed to register Android SensorEventListener.",
          "errorCode" to "REGISTER_LISTENER_FAILED"
        )
      )
      return
    }

    emitEvent(
      mapOf(
        "sessionId" to sessionId,
        "eventType" to "calibrationStarted",
        "summary" to "Calibrating baseline on ${sensor.name}...",
        "threshold" to motionThreshold,
        "timestampMs" to sessionStartTimeMs
      )
    )

    result.success(
      mapOf(
        "started" to true,
        "message" to "Monitoring active on ${sensor.name}."
      )
    )
  }

  private fun stopMonitoringInternal() {
    sensorManager?.unregisterListener(this)
    activeSensor = null
    activeSessionId = null
    consecutiveAboveThreshold = 0
  }

  override fun onSensorChanged(event: SensorEvent?) {
    val sessionId = activeSessionId ?: return
    val values = event?.values ?: return
    if (values.size < 3) return

    // Convert m/s^2 to g-units (1g = 9.80665 m/s^2)
    val ax = values[0].toDouble() / 9.80665
    val ay = values[1].toDouble() / 9.80665
    val az = values[2].toDouble() / 9.80665
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
            "summary" to "Android motion baseline calibrated. Active motion detection enabled.",
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
      emitEvent(
        mapOf(
          "sessionId" to sessionId,
          "eventType" to "motionTriggered",
          "summary" to String.format(
            "Android motion trigger (score %.3f >= threshold %.3f, %.2fg delta)",
            motionScore,
            motionThreshold,
            combinedDeltaG
          ),
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
            "Android motion score %.3f (%.2fg delta)",
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

  fun onHostPause() {
    val sessionId = activeSessionId ?: return
    emitEvent(
      mapOf(
        "sessionId" to sessionId,
        "eventType" to "lifecyclePaused",
        "summary" to "Android activity backgrounded; motion monitoring paused.",
        "timestampMs" to System.currentTimeMillis()
      )
    )
  }

  fun onHostResume() {
    val sessionId = activeSessionId ?: return
    emitEvent(
      mapOf(
        "sessionId" to sessionId,
        "eventType" to "lifecycleResumed",
        "summary" to "Android activity resumed in foreground.",
        "timestampMs" to System.currentTimeMillis()
      )
    )
  }

  private fun emitEvent(payload: Map<String, Any>) {
    mainHandler.post {
      eventSink?.success(payload)
    }
  }

  fun dispose() {
    stopMonitoringInternal()
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
