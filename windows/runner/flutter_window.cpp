#include "flutter_window.h"

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <dpapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mmsystem.h>
#include <roapi.h>
#include <sensors.h>
#include <sensorsapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <windows.devices.sensors.h>
#include <winstring.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fstream>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

using Microsoft::WRL::ComPtr;

constexpr UINT kWmFlutterBridgeCallback = WM_APP + 0x42;

int64_t CurrentTimeMillis() {
  const auto now = std::chrono::system_clock::now();
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             now.time_since_epoch())
      .count();
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  int required = ::WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), nullptr, 0,
      nullptr, nullptr);
  if (required <= 0) {
    return std::string();
  }
  std::string result(static_cast<size_t>(required), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                        result.data(), required, nullptr, nullptr);
  return result;
}

const flutter::EncodableMap* GetArgsMap(const flutter::EncodableValue* args) {
  if (args == nullptr) {
    return nullptr;
  }
  return std::get_if<flutter::EncodableMap>(args);
}

std::string GetStringArg(const flutter::EncodableMap* map, const char* key,
                         const std::string& fallback) {
  if (map == nullptr) {
    return fallback;
  }
  auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) {
    return fallback;
  }
  if (const auto* str = std::get_if<std::string>(&it->second)) {
    return *str;
  }
  return fallback;
}

double GetDoubleArg(const flutter::EncodableMap* map, const char* key,
                    double fallback) {
  if (map == nullptr) {
    return fallback;
  }
  auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) {
    return fallback;
  }
  if (const auto* dbl = std::get_if<double>(&it->second)) {
    return *dbl;
  }
  if (const auto* i32 = std::get_if<int32_t>(&it->second)) {
    return static_cast<double>(*i32);
  }
  if (const auto* i64 = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*i64);
  }
  return fallback;
}

int32_t GetIntArg(const flutter::EncodableMap* map, const char* key,
                  int32_t fallback) {
  if (map == nullptr) {
    return fallback;
  }
  auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) {
    return fallback;
  }
  if (const auto* i32 = std::get_if<int32_t>(&it->second)) {
    return *i32;
  }
  if (const auto* i64 = std::get_if<int64_t>(&it->second)) {
    return static_cast<int32_t>(*i64);
  }
  if (const auto* dbl = std::get_if<double>(&it->second)) {
    return static_cast<int32_t>(*dbl);
  }
  return fallback;
}

const std::vector<uint8_t>* GetBytesArg(const flutter::EncodableMap* map,
                                        const char* key) {
  if (map == nullptr) {
    return nullptr;
  }
  auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) {
    return nullptr;
  }
  return std::get_if<std::vector<uint8_t>>(&it->second);
}

// Dispatches tasks from background sensor/camera threads onto the Win32 main UI
// thread so that Flutter MethodChannel and EventSink calls always execute on
// the platform thread.
class MainThreadDispatcher {
 public:
  explicit MainThreadDispatcher(HWND hwnd) : hwnd_(hwnd) {}

  void Post(std::function<void()> task) {
    HWND target = nullptr;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!alive_ || hwnd_ == nullptr) {
        return;
      }
      tasks_.push_back(std::move(task));
      target = hwnd_;
    }
    ::PostMessage(target, kWmFlutterBridgeCallback, 0, 0);
  }

  void DrainTasks() {
    std::deque<std::function<void()>> pending;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!alive_) {
        tasks_.clear();
        return;
      }
      pending.swap(tasks_);
    }
    for (auto& task : pending) {
      if (task) {
        task();
      }
    }
  }

  void Shutdown() {
    std::lock_guard<std::mutex> lock(mutex_);
    alive_ = false;
    hwnd_ = nullptr;
    tasks_.clear();
  }

 private:
  std::mutex mutex_;
  HWND hwnd_ = nullptr;
  bool alive_ = true;
  std::deque<std::function<void()>> tasks_;
};

// ============================================================================
// 1. Windows Native Audio Alarm Bridge (`dev.watsafe/audio_alarm`)
// ============================================================================

class WindowsAudioAlarmBridge {
 public:
  WindowsAudioAlarmBridge(flutter::BinaryMessenger* messenger,
                          std::shared_ptr<MainThreadDispatcher> dispatcher)
      : dispatcher_(std::move(dispatcher)) {
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, "dev.watsafe/audio_alarm",
        &flutter::StandardMethodCodec::GetInstance());

    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) { HandleMethodCall(call, std::move(result)); });
  }

  ~WindowsAudioAlarmBridge() { StopPlayback(); }

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto* args = GetArgsMap(call.arguments());
    const std::string& method = call.method_name();

    if (method == "startLoopingAlarm") {
      const double volume = std::clamp(GetDoubleArg(args, "volume", 0.85), 0.0, 1.0);
      const auto* wav_bytes = GetBytesArg(args, "wavBytes");
      StartPlayback(wav_bytes, volume, 0);
      result->Success();
      return;
    }

    if (method == "startTestAlarm") {
      const double volume = std::clamp(GetDoubleArg(args, "volume", 0.85), 0.0, 1.0);
      const int32_t max_duration_ms =
          std::clamp(GetIntArg(args, "maxDurationMs", 5000), 500, 5000);
      const auto* wav_bytes = GetBytesArg(args, "wavBytes");
      StartPlayback(wav_bytes, volume, max_duration_ms);
      result->Success();
      return;
    }

    if (method == "stopAlarm") {
      StopPlayback();
      result->Success();
      return;
    }

    if (method == "setVolume") {
      const double volume = std::clamp(GetDoubleArg(args, "volume", 0.85), 0.0, 1.0);
      volume_ = volume;
      if (is_playing_ && !raw_wav_bytes_.empty()) {
        RebuildScaledWavBuffer(volume_);
        ::PlaySoundW(reinterpret_cast<LPCWSTR>(scaled_wav_bytes_.data()),
                     nullptr,
                     SND_MEMORY | SND_ASYNC | SND_LOOP | SND_NODEFAULT);
      }
      result->Success();
      return;
    }

    result->NotImplemented();
  }

  void StartPlayback(const std::vector<uint8_t>* wav_bytes, double volume,
                     int32_t max_duration_ms) {
    StopPlayback();
    volume_ = volume;
    if (wav_bytes != nullptr && wav_bytes->size() > 44) {
      raw_wav_bytes_ = *wav_bytes;
    }

    if (raw_wav_bytes_.size() <= 44) {
      ::MessageBeep(MB_ICONWARNING);
      return;
    }

    RebuildScaledWavBuffer(volume_);
    BOOL ok = ::PlaySoundW(reinterpret_cast<LPCWSTR>(scaled_wav_bytes_.data()),
                           nullptr,
                           SND_MEMORY | SND_ASYNC | SND_LOOP | SND_NODEFAULT);
    if (!ok) {
      ::MessageBeep(MB_ICONWARNING);
      return;
    }
    is_playing_ = true;
    const uint64_t token = ++playback_generation_;

    if (max_duration_ms > 0) {
      auto dispatcher = dispatcher_;
      std::thread([this, dispatcher, token, max_duration_ms]() {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(max_duration_ms));
        dispatcher->Post([this, token]() {
          if (playback_generation_ == token && is_playing_) {
            StopPlayback();
          }
        });
      }).detach();
    }
  }

  void RebuildScaledWavBuffer(double volume) {
    scaled_wav_bytes_ = raw_wav_bytes_;
    if (scaled_wav_bytes_.size() <= 44) {
      return;
    }
    // Scale 16-bit signed little-endian PCM samples after the 44-byte WAV header.
    const double clamped = std::clamp(volume, 0.0, 1.0);
    for (size_t i = 44; i + 1 < scaled_wav_bytes_.size(); i += 2) {
      int16_t sample = static_cast<int16_t>(
          static_cast<uint16_t>(scaled_wav_bytes_[i]) |
          (static_cast<uint16_t>(scaled_wav_bytes_[i + 1]) << 8));
      int32_t scaled = static_cast<int32_t>(std::lround(sample * clamped));
      scaled = std::clamp(scaled, -32768, 32767);
      const uint16_t encoded = static_cast<uint16_t>(static_cast<int16_t>(scaled));
      scaled_wav_bytes_[i] = static_cast<uint8_t>(encoded & 0xFF);
      scaled_wav_bytes_[i + 1] = static_cast<uint8_t>((encoded >> 8) & 0xFF);
    }
  }

  void StopPlayback() {
    ++playback_generation_;
    if (is_playing_) {
      ::PlaySoundW(nullptr, nullptr, 0);
      is_playing_ = false;
    }
  }

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::shared_ptr<MainThreadDispatcher> dispatcher_;
  std::vector<uint8_t> raw_wav_bytes_;
  std::vector<uint8_t> scaled_wav_bytes_;
  double volume_ = 0.85;
  bool is_playing_ = false;
  uint64_t playback_generation_ = 0;
};

// ============================================================================
// 2. Windows DPAPI Secure Storage Bridge (`dev.watsafe/secure_storage`)
// ============================================================================

class WindowsSecureStorageBridge {
 public:
  explicit WindowsSecureStorageBridge(flutter::BinaryMessenger* messenger) {
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, "dev.watsafe/secure_storage",
        &flutter::StandardMethodCodec::GetInstance());

    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) { HandleMethodCall(call, std::move(result)); });
  }

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const std::string& method = call.method_name();

    if (method == "readPinRecord") {
      std::string decrypted = ReadFromDpapiFile();
      if (decrypted.empty()) {
        result->Success(flutter::EncodableValue());
      } else {
        result->Success(flutter::EncodableValue(decrypted));
      }
      return;
    }

    if (method == "writePinRecord") {
      const auto* args = GetArgsMap(call.arguments());
      const std::string payload = GetStringArg(args, "payload", "");
      if (payload.empty()) {
        result->Error("INVALID_ARGUMENTS",
                      "Missing payload for writePinRecord");
        return;
      }
      if (WriteToDpapiFile(payload)) {
        result->Success(flutter::EncodableValue(
            std::string("Windows DPAPI (CryptProtectData PBKDF2-HMAC-SHA256)")));
      } else {
        result->Error("DPAPI_WRITE_FAILED",
                      "Failed to encrypt and store PIN record via DPAPI.");
      }
      return;
    }

    if (method == "deletePinRecord") {
      const std::wstring path = ResolveDpapiFilePath();
      if (!path.empty()) {
        ::DeleteFileW(path.c_str());
      }
      result->Success();
      return;
    }

    result->NotImplemented();
  }

  std::wstring ResolveDpapiFilePath() {
    PWSTR roaming_path = nullptr;
    HRESULT hr =
        ::SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &roaming_path);
    if (FAILED(hr) || roaming_path == nullptr) {
      return std::wstring();
    }
    std::wstring dir(roaming_path);
    ::CoTaskMemFree(roaming_path);
    dir += L"\\dev.watsafe.temp.watsafe";
    ::CreateDirectoryW(dir.c_str(), nullptr);
    return dir + L"\\secure_pin_record.dpapi";
  }

  bool WriteToDpapiFile(const std::string& payload) {
    const std::wstring path = ResolveDpapiFilePath();
    if (path.empty()) {
      return false;
    }

    DATA_BLOB in_blob{};
    in_blob.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(payload.data()));
    in_blob.cbData = static_cast<DWORD>(payload.size());

    DATA_BLOB out_blob{};
    BOOL encrypted = ::CryptProtectData(&in_blob, L"WATSafe PIN Record",
                                        nullptr, nullptr, nullptr,
                                        CRYPTPROTECT_UI_FORBIDDEN, &out_blob);
    if (!encrypted || out_blob.pbData == nullptr) {
      return false;
    }

    std::ofstream out_file(path, std::ios::binary | std::ios::trunc);
    bool wrote = false;
    if (out_file.is_open()) {
      out_file.write(reinterpret_cast<const char*>(out_blob.pbData),
                     static_cast<std::streamsize>(out_blob.cbData));
      wrote = out_file.good();
      out_file.close();
    }
    ::LocalFree(out_blob.pbData);
    return wrote;
  }

  std::string ReadFromDpapiFile() {
    const std::wstring path = ResolveDpapiFilePath();
    if (path.empty()) {
      return std::string();
    }

    std::ifstream in_file(path, std::ios::binary | std::ios::ate);
    if (!in_file.is_open()) {
      return std::string();
    }
    const std::streamsize size = in_file.tellg();
    if (size <= 0) {
      return std::string();
    }
    in_file.seekg(0, std::ios::beg);
    std::vector<uint8_t> encrypted(static_cast<size_t>(size));
    if (!in_file.read(reinterpret_cast<char*>(encrypted.data()), size)) {
      return std::string();
    }

    DATA_BLOB in_blob{};
    in_blob.pbData = encrypted.data();
    in_blob.cbData = static_cast<DWORD>(encrypted.size());

    DATA_BLOB out_blob{};
    BOOL ok = ::CryptUnprotectData(&in_blob, nullptr, nullptr, nullptr, nullptr,
                                   CRYPTPROTECT_UI_FORBIDDEN, &out_blob);
    if (!ok || out_blob.pbData == nullptr) {
      return std::string();
    }

    std::string plaintext(reinterpret_cast<const char*>(out_blob.pbData),
                          static_cast<size_t>(out_blob.cbData));
    ::LocalFree(out_blob.pbData);
    return plaintext;
  }

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

// ============================================================================
// 3. Windows Hardware Accelerometer Bridge
//    (`dev.watsafe/windows_accelerometer` & `dev.watsafe/windows_accelerometer_events`)
// ============================================================================

struct AccelerometerProbeResult {
  bool has_hardware = false;
  std::string device_name = "No Accelerometer Detected";
  std::string permission_status = "notApplicable";
  std::string detail;
  ComPtr<ABI::Windows::Devices::Sensors::IAccelerometer> winrt_accelerometer;
  ComPtr<ISensor> win32_sensor;
};

AccelerometerProbeResult ProbeAccelerometerHardware() {
  AccelerometerProbeResult result;

  // 1. Try WinRT Windows.Devices.Sensors.Accelerometer.GetDefault()
  HSTRING_HEADER header{};
  HSTRING class_id = nullptr;
  const wchar_t kClassName[] =
      L"Windows.Devices.Sensors.Accelerometer";
  HRESULT hr = ::WindowsCreateStringReference(
      kClassName, static_cast<UINT32>((sizeof(kClassName) / sizeof(wchar_t)) - 1),
      &header, &class_id);
  if (SUCCEEDED(hr) && class_id != nullptr) {
    ComPtr<ABI::Windows::Devices::Sensors::IAccelerometerStatics> statics;
    hr = ::RoGetActivationFactory(
        class_id,
        __uuidof(ABI::Windows::Devices::Sensors::IAccelerometerStatics),
        reinterpret_cast<void**>(statics.GetAddressOf()));
    if (SUCCEEDED(hr) && statics != nullptr) {
      ComPtr<ABI::Windows::Devices::Sensors::IAccelerometer> accel;
      hr = statics->GetDefault(accel.GetAddressOf());
      if (SUCCEEDED(hr) && accel != nullptr) {
        result.has_hardware = true;
        result.device_name = "Windows Integrated 3-Axis Accelerometer (WinRT)";
        result.permission_status = "granted";
        result.detail =
            "3-axis accelerometer acquired via Windows.Devices.Sensors.Accelerometer.GetDefault().";
        result.winrt_accelerometer = accel;
      }
    }
  }

  // 2. Also inspect Win32 ISensorManager (SENSOR_TYPE_ACCELEROMETER_3D,
  //    SENSOR_CATEGORY_MOTION, and SENSOR_CATEGORY_ORIENTATION) to obtain
  //    friendly hardware name or fallback composite HID motion/tilt sensor.
  ComPtr<ISensorManager> sensor_manager;
  hr = ::CoCreateInstance(CLSID_SensorManager, nullptr, CLSCTX_INPROC_SERVER,
                          IID_PPV_ARGS(sensor_manager.GetAddressOf()));
  if (SUCCEEDED(hr) && sensor_manager != nullptr) {
    ComPtr<ISensorCollection> collection;
    hr = sensor_manager->GetSensorsByType(SENSOR_TYPE_ACCELEROMETER_3D,
                                          collection.GetAddressOf());
    ULONG count = 0;
    if (FAILED(hr) || collection == nullptr ||
        FAILED(collection->GetCount(&count)) || count == 0) {
      collection.Reset();
      hr = sensor_manager->GetSensorsByCategory(SENSOR_CATEGORY_MOTION,
                                                collection.GetAddressOf());
      if (FAILED(hr) || collection == nullptr ||
          FAILED(collection->GetCount(&count)) || count == 0) {
        collection.Reset();
        hr = sensor_manager->GetSensorsByCategory(SENSOR_CATEGORY_ORIENTATION,
                                                  collection.GetAddressOf());
      }
    }
    if (SUCCEEDED(hr) && collection != nullptr) {
      count = 0;
      if (SUCCEEDED(collection->GetCount(&count)) && count > 0) {
        ComPtr<ISensor> sensor;
        if (SUCCEEDED(collection->GetAt(0, sensor.GetAddressOf())) &&
            sensor != nullptr) {
          BSTR friendly_bstr = nullptr;
          if (SUCCEEDED(sensor->GetFriendlyName(&friendly_bstr)) &&
              friendly_bstr != nullptr) {
            std::wstring wide_name(friendly_bstr, ::SysStringLen(friendly_bstr));
            ::SysFreeString(friendly_bstr);
            if (!wide_name.empty()) {
              result.device_name = WideToUtf8(wide_name);
            }
          }

          SensorState state = SENSOR_STATE_READY;
          if (SUCCEEDED(sensor->GetState(&state)) &&
              state == SENSOR_STATE_ACCESS_DENIED) {
            result.permission_status = "denied";
          } else {
            result.permission_status = "granted";
          }

          if (!result.has_hardware) {
            result.has_hardware = true;
            result.detail =
                "Motion/orientation sensor discovered via Windows Sensor API (ISensorManager).";
          }
          result.win32_sensor = sensor;
        }
      }
    }
  }

  if (!result.has_hardware) {
    result.permission_status = "notApplicable";
    result.detail =
        "Windows.Devices.Sensors.Accelerometer.GetDefault() returned nullptr and "
        "ISensorManager found 0 3D accelerometer sensors on this PC.";
  }

  return result;
}

class WindowsAccelerometerBridge {
 public:
  WindowsAccelerometerBridge(flutter::BinaryMessenger* messenger,
                             std::shared_ptr<MainThreadDispatcher> dispatcher)
      : dispatcher_(std::move(dispatcher)) {
    method_channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            messenger, "dev.watsafe/windows_accelerometer",
            &flutter::StandardMethodCodec::GetInstance());
    event_channel_ =
        std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
            messenger, "dev.watsafe/windows_accelerometer_events",
            &flutter::StandardMethodCodec::GetInstance());

    method_channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) { HandleMethodCall(call, std::move(result)); });

    auto handler = std::make_unique<
        flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
        [this](const flutter::EncodableValue* arguments,
               std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                   events)
            -> std::unique_ptr<
                flutter::StreamHandlerError<flutter::EncodableValue>> {
          event_sink_ = std::move(events);
          return nullptr;
        },
        [this](const flutter::EncodableValue* arguments)
            -> std::unique_ptr<
                flutter::StreamHandlerError<flutter::EncodableValue>> {
          event_sink_.reset();
          return nullptr;
        });
    event_channel_->SetStreamHandler(std::move(handler));
  }

  ~WindowsAccelerometerBridge() { StopCapture(); }

  void OnSystemSuspend() {
    std::string session_id;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      session_id = active_session_id_;
    }
    if (!session_id.empty()) {
      EmitEvent(flutter::EncodableMap{
          {flutter::EncodableValue("sessionId"),
           flutter::EncodableValue(session_id)},
          {flutter::EncodableValue("eventType"),
           flutter::EncodableValue("lifecyclePaused")},
          {flutter::EncodableValue("summary"),
           flutter::EncodableValue(
               "Windows system entering sleep; accelerometer monitoring paused.")},
          {flutter::EncodableValue("timestampMs"),
           flutter::EncodableValue(CurrentTimeMillis())},
      });
    }
  }

  void OnSystemResume() {
    std::string session_id;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      session_id = active_session_id_;
    }
    if (!session_id.empty()) {
      EmitEvent(flutter::EncodableMap{
          {flutter::EncodableValue("sessionId"),
           flutter::EncodableValue(session_id)},
          {flutter::EncodableValue("eventType"),
           flutter::EncodableValue("lifecycleResumed")},
          {flutter::EncodableValue("summary"),
           flutter::EncodableValue(
               "Windows system woke from sleep; accelerometer monitoring resumed.")},
          {flutter::EncodableValue("timestampMs"),
           flutter::EncodableValue(CurrentTimeMillis())},
      });
    }
  }

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const std::string& method = call.method_name();
    const auto* args = GetArgsMap(call.arguments());

    if (method == "checkCapability") {
      const AccelerometerProbeResult probe = ProbeAccelerometerHardware();
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("hasAccelerometerHardware"),
           flutter::EncodableValue(probe.has_hardware)},
          {flutter::EncodableValue("deviceName"),
           flutter::EncodableValue(probe.device_name)},
          {flutter::EncodableValue("permissionStatus"),
           flutter::EncodableValue(probe.permission_status)},
          {flutter::EncodableValue("detail"),
           flutter::EncodableValue(probe.detail)},
      }));
      return;
    }

    if (method == "requestPermission") {
      const AccelerometerProbeResult probe = ProbeAccelerometerHardware();
      if (probe.permission_status == "denied") {
        ::ShellExecuteW(nullptr, L"open", L"ms-settings:privacy-motion",
                        nullptr, nullptr, SW_SHOWNORMAL);
      }
      result->Success(flutter::EncodableValue(probe.permission_status));
      return;
    }

    if (method == "startMonitoring") {
      StartMonitoring(args, std::move(result));
      return;
    }

    if (method == "updateSensitivity") {
      const double threshold =
          std::clamp(GetDoubleArg(args, "motionScoreThreshold", 0.095), 0.02, 0.50);
      motion_threshold_.store(threshold);
      result->Success();
      return;
    }

    if (method == "stopMonitoring") {
      StopCapture();
      result->Success();
      return;
    }

    result->NotImplemented();
  }

  void StartMonitoring(
      const flutter::EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    StopCapture();

    const std::string session_id =
        GetStringArg(args, "sessionId", "session_default");
    const double threshold =
        std::clamp(GetDoubleArg(args, "motionScoreThreshold", 0.095), 0.02, 0.50);
    const int32_t calibration_ms =
        std::max<int32_t>(500, GetIntArg(args, "calibrationDurationMs", 1500));
    const int32_t persistence_frames =
        std::max<int32_t>(1, GetIntArg(args, "persistenceFramesRequired", 3));

    const AccelerometerProbeResult probe = ProbeAccelerometerHardware();
    if (!probe.has_hardware) {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("started"), flutter::EncodableValue(false)},
          {flutter::EncodableValue("message"),
           flutter::EncodableValue(
               "No integrated Windows 3-axis accelerometer hardware found.")},
          {flutter::EncodableValue("errorCode"),
           flutter::EncodableValue("NO_ACCELEROMETER_HARDWARE")},
      }));
      return;
    }

    if (probe.permission_status == "denied") {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("started"), flutter::EncodableValue(false)},
          {flutter::EncodableValue("message"),
           flutter::EncodableValue(
               "Windows motion sensor access is denied in Privacy Settings.")},
          {flutter::EncodableValue("errorCode"),
           flutter::EncodableValue("PERMISSION_NOT_GRANTED")},
      }));
      return;
    }

    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      active_session_id_ = session_id;
    }
    motion_threshold_.store(threshold);
    running_.store(true);

    const std::string device_name = probe.device_name;
    EmitEvent(flutter::EncodableMap{
        {flutter::EncodableValue("sessionId"),
         flutter::EncodableValue(session_id)},
        {flutter::EncodableValue("eventType"),
         flutter::EncodableValue("calibrationStarted")},
        {flutter::EncodableValue("summary"),
         flutter::EncodableValue("Calibrating 1g resting baseline on " +
                                 device_name + "...")},
        {flutter::EncodableValue("threshold"),
         flutter::EncodableValue(threshold)},
        {flutter::EncodableValue("timestampMs"),
         flutter::EncodableValue(CurrentTimeMillis())},
    });

    worker_thread_ = std::thread([this, session_id, calibration_ms,
                                  persistence_frames]() {
      RunSensorLoop(session_id, calibration_ms, persistence_frames);
    });

    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("started"), flutter::EncodableValue(true)},
        {flutter::EncodableValue("message"),
         flutter::EncodableValue("Monitoring active on " + device_name + ".")},
    }));
  }

  void RunSensorLoop(const std::string& session_id, int32_t calibration_ms,
                     int32_t persistence_frames) {
    ::RoInitialize(RO_INIT_MULTITHREADED);
    ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    AccelerometerProbeResult probe = ProbeAccelerometerHardware();
    if (!probe.has_hardware) {
      EmitEvent(flutter::EncodableMap{
          {flutter::EncodableValue("sessionId"),
           flutter::EncodableValue(session_id)},
          {flutter::EncodableValue("eventType"),
           flutter::EncodableValue("detectorFailed")},
          {flutter::EncodableValue("summary"),
           flutter::EncodableValue(
               "Accelerometer hardware became unavailable during startup.")},
          {flutter::EncodableValue("errorCode"),
           flutter::EncodableValue("SENSOR_UNAVAILABLE")},
          {flutter::EncodableValue("timestampMs"),
           flutter::EncodableValue(CurrentTimeMillis())},
      });
      ::CoUninitialize();
      ::RoUninitialize();
      return;
    }

    if (probe.winrt_accelerometer != nullptr) {
      UINT32 min_interval = 16;
      if (SUCCEEDED(
              probe.winrt_accelerometer->get_MinimumReportInterval(&min_interval))) {
        const UINT32 target_interval = std::max<UINT32>(min_interval, 40);
        probe.winrt_accelerometer->put_ReportInterval(target_interval);
      }
    }

    const int64_t start_time_ms = CurrentTimeMillis();
    bool calibration_done = false;
    bool has_baseline = false;
    double ref_x = 0.0;
    double ref_y = 0.0;
    double ref_z = -1.0;
    double ref_mag = 1.0;
    int32_t consecutive_above = 0;
    int32_t sample_count = 0;

    while (running_.load()) {
      double ax = 0.0;
      double ay = 0.0;
      double az = 0.0;
      bool got_sample = false;

      if (probe.winrt_accelerometer != nullptr) {
        ComPtr<ABI::Windows::Devices::Sensors::IAccelerometerReading> reading;
        if (SUCCEEDED(
                probe.winrt_accelerometer->GetCurrentReading(reading.GetAddressOf())) &&
            reading != nullptr) {
          if (SUCCEEDED(reading->get_AccelerationX(&ax)) &&
              SUCCEEDED(reading->get_AccelerationY(&ay)) &&
              SUCCEEDED(reading->get_AccelerationZ(&az))) {
            got_sample = true;
          }
        }
      } else if (probe.win32_sensor != nullptr) {
        ComPtr<ISensorDataReport> report;
        if (SUCCEEDED(probe.win32_sensor->GetData(report.GetAddressOf())) &&
            report != nullptr) {
          PROPVARIANT vx{};
          PROPVARIANT vy{};
          PROPVARIANT vz{};
          ::PropVariantInit(&vx);
          ::PropVariantInit(&vy);
          ::PropVariantInit(&vz);
          if (SUCCEEDED(report->GetSensorValue(SENSOR_DATA_TYPE_ACCELERATION_X_G, &vx)) &&
              SUCCEEDED(report->GetSensorValue(SENSOR_DATA_TYPE_ACCELERATION_Y_G, &vy)) &&
              SUCCEEDED(report->GetSensorValue(SENSOR_DATA_TYPE_ACCELERATION_Z_G, &vz))) {
            ax = (vx.vt == VT_R8) ? vx.dblVal : ((vx.vt == VT_R4) ? vx.fltVal : 0.0);
            ay = (vy.vt == VT_R8) ? vy.dblVal : ((vy.vt == VT_R4) ? vy.fltVal : 0.0);
            az = (vz.vt == VT_R8) ? vz.dblVal : ((vz.vt == VT_R4) ? vz.fltVal : 0.0);
            got_sample = true;
          } else if (SUCCEEDED(report->GetSensorValue(SENSOR_DATA_TYPE_TILT_X_DEGREES, &vx)) &&
                     SUCCEEDED(report->GetSensorValue(SENSOR_DATA_TYPE_TILT_Y_DEGREES, &vy)) &&
                     SUCCEEDED(report->GetSensorValue(SENSOR_DATA_TYPE_TILT_Z_DEGREES, &vz))) {
            const double tx_deg = (vx.vt == VT_R8) ? vx.dblVal : ((vx.vt == VT_R4) ? vx.fltVal : 0.0);
            const double ty_deg = (vy.vt == VT_R8) ? vy.dblVal : ((vy.vt == VT_R4) ? vy.fltVal : 0.0);
            const double tz_deg = (vz.vt == VT_R8) ? vz.dblVal : ((vz.vt == VT_R4) ? vz.fltVal : 0.0);
            constexpr double kDegToRad = 3.14159265358979323846 / 180.0;
            ax = std::sin(tx_deg * kDegToRad);
            ay = std::sin(ty_deg * kDegToRad);
            az = std::cos(tz_deg * kDegToRad);
            got_sample = true;
          }
          ::PropVariantClear(&vx);
          ::PropVariantClear(&vy);
          ::PropVariantClear(&vz);
        }
      }

      if (got_sample) {
        sample_count += 1;
        const int64_t now_ms = CurrentTimeMillis();
        const double mag = std::sqrt((ax * ax) + (ay * ay) + (az * az));
        const double active_threshold = motion_threshold_.load();

        if (!has_baseline) {
          ref_x = ax;
          ref_y = ay;
          ref_z = az;
          ref_mag = (mag > 0.05) ? mag : 1.0;
          has_baseline = true;
        } else if (!calibration_done) {
          ref_x = (0.70 * ref_x) + (0.30 * ax);
          ref_y = (0.70 * ref_y) + (0.30 * ay);
          ref_z = (0.70 * ref_z) + (0.30 * az);
          ref_mag = (0.70 * ref_mag) + (0.30 * mag);

          if ((now_ms - start_time_ms) >= calibration_ms && sample_count >= 5) {
            calibration_done = true;
            EmitEvent(flutter::EncodableMap{
                {flutter::EncodableValue("sessionId"),
                 flutter::EncodableValue(session_id)},
                {flutter::EncodableValue("eventType"),
                 flutter::EncodableValue("calibrationCompleted")},
                {flutter::EncodableValue("summary"),
                 flutter::EncodableValue(
                     "Accelerometer 1g resting baseline calibrated. Active motion detection enabled.")},
                {flutter::EncodableValue("motionScore"),
                 flutter::EncodableValue(0.0)},
                {flutter::EncodableValue("threshold"),
                 flutter::EncodableValue(active_threshold)},
                {flutter::EncodableValue("consecutiveFrames"),
                 flutter::EncodableValue(static_cast<int32_t>(0))},
                {flutter::EncodableValue("timestampMs"),
                 flutter::EncodableValue(now_ms)},
            });
          }
        } else {
          const double dx = ax - ref_x;
          const double dy = ay - ref_y;
          const double dz = az - ref_z;
          const double vector_delta = std::sqrt((dx * dx) + (dy * dy) + (dz * dz));
          const double mag_delta = std::abs(mag - ref_mag);
          const double motion_score =
              std::clamp(std::max(vector_delta, mag_delta), 0.0, 1.0);

          if (motion_score < (active_threshold * 0.5)) {
            ref_x = (0.98 * ref_x) + (0.02 * ax);
            ref_y = (0.98 * ref_y) + (0.02 * ay);
            ref_z = (0.98 * ref_z) + (0.02 * az);
            ref_mag = (0.98 * ref_mag) + (0.02 * mag);
          }

          if (motion_score >= active_threshold) {
            consecutive_above += 1;
          } else {
            consecutive_above = 0;
          }

          if (consecutive_above >= persistence_frames) {
            char summary_buf[180];
            std::snprintf(
                summary_buf, sizeof(summary_buf),
                "Sustained accelerometer motion detected (delta %.3fg >= threshold %.3fg across %d samples)",
                motion_score, active_threshold, consecutive_above);
            EmitEvent(flutter::EncodableMap{
                {flutter::EncodableValue("sessionId"),
                 flutter::EncodableValue(session_id)},
                {flutter::EncodableValue("eventType"),
                 flutter::EncodableValue("motionTriggered")},
                {flutter::EncodableValue("summary"),
                 flutter::EncodableValue(std::string(summary_buf))},
                {flutter::EncodableValue("motionScore"),
                 flutter::EncodableValue(motion_score)},
                {flutter::EncodableValue("threshold"),
                 flutter::EncodableValue(active_threshold)},
                {flutter::EncodableValue("consecutiveFrames"),
                 flutter::EncodableValue(consecutive_above)},
                {flutter::EncodableValue("timestampMs"),
                 flutter::EncodableValue(now_ms)},
            });
          } else if (sample_count % 4 == 0) {
            char summary_buf[140];
            std::snprintf(summary_buf, sizeof(summary_buf),
                          "Accelerometer delta %.3fg (threshold %.3fg)",
                          motion_score, active_threshold);
            EmitEvent(flutter::EncodableMap{
                {flutter::EncodableValue("sessionId"),
                 flutter::EncodableValue(session_id)},
                {flutter::EncodableValue("eventType"),
                 flutter::EncodableValue("telemetryFrame")},
                {flutter::EncodableValue("summary"),
                 flutter::EncodableValue(std::string(summary_buf))},
                {flutter::EncodableValue("motionScore"),
                 flutter::EncodableValue(motion_score)},
                {flutter::EncodableValue("threshold"),
                 flutter::EncodableValue(active_threshold)},
                {flutter::EncodableValue("consecutiveFrames"),
                 flutter::EncodableValue(consecutive_above)},
                {flutter::EncodableValue("timestampMs"),
                 flutter::EncodableValue(now_ms)},
            });
          }
        }
      }

      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    if (probe.winrt_accelerometer != nullptr) {
      probe.winrt_accelerometer->put_ReportInterval(0);
    }

    ::CoUninitialize();
    ::RoUninitialize();
  }

  void StopCapture() {
    running_.store(false);
    if (worker_thread_.joinable()) {
      worker_thread_.join();
    }
    std::lock_guard<std::mutex> lock(state_mutex_);
    active_session_id_.clear();
  }

  void EmitEvent(flutter::EncodableMap payload) {
    dispatcher_->Post([this, payload = std::move(payload)]() {
      if (event_sink_) {
        event_sink_->Success(flutter::EncodableValue(payload));
      }
    });
  }

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::shared_ptr<MainThreadDispatcher> dispatcher_;

  std::mutex state_mutex_;
  std::string active_session_id_;
  std::atomic<bool> running_{false};
  std::atomic<double> motion_threshold_{0.095};
  std::thread worker_thread_;
};

// ============================================================================
// 4. Windows Media Foundation Webcam Scene-Motion Bridge
//    (`dev.watsafe/windows_camera` & `dev.watsafe/windows_camera_events`)
// ============================================================================

bool IsRegistryWebcamDenied(HKEY root, const wchar_t* subkey) {
  wchar_t buffer[64] = {};
  DWORD byte_size = sizeof(buffer);
  LSTATUS status = ::RegGetValueW(root, subkey, L"Value", RRF_RT_REG_SZ,
                                  nullptr, buffer, &byte_size);
  if (status == ERROR_SUCCESS) {
    if (_wcsicmp(buffer, L"Deny") == 0) {
      return true;
    }
  }
  return false;
}

std::string QueryWindowsCameraPermissionStatus() {
  if (IsRegistryWebcamDenied(
          HKEY_LOCAL_MACHINE,
          L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam") ||
      IsRegistryWebcamDenied(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam") ||
      IsRegistryWebcamDenied(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam\\NonPackaged")) {
    return "denied";
  }
  return "granted";
}

struct CameraDeviceProbe {
  bool has_hardware = false;
  std::string device_name = "No Camera Detected";
  std::string permission_status = "granted";
  std::string detail;
  ComPtr<IMFActivate> activate;
};

CameraDeviceProbe ProbeWindowsCamera() {
  CameraDeviceProbe result;
  result.permission_status = QueryWindowsCameraPermissionStatus();

  ComPtr<IMFAttributes> attributes;
  HRESULT hr = ::MFCreateAttributes(attributes.GetAddressOf(), 1);
  if (FAILED(hr) || attributes == nullptr) {
    result.detail = "MFCreateAttributes failed during camera discovery.";
    return result;
  }

  hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                           MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  if (FAILED(hr)) {
    result.detail = "Failed to set MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID.";
    return result;
  }

  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  hr = ::MFEnumDeviceSources(attributes.Get(), &devices, &count);
  if (FAILED(hr) || count == 0 || devices == nullptr) {
    result.detail =
        "No video capture devices reported by Media Foundation MFEnumDeviceSources.";
    if (devices != nullptr) {
      ::CoTaskMemFree(devices);
    }
    return result;
  }

  result.has_hardware = true;

  int best_index = 0;
  int best_score = -10000;
  std::string best_name = "Windows Video Capture Device";

  for (UINT32 i = 0; i < count; ++i) {
    if (devices[i] == nullptr) {
      continue;
    }

    std::string candidate_name = "Windows Video Capture Device";
    WCHAR* friendly_name = nullptr;
    UINT32 name_len = 0;
    if (SUCCEEDED(devices[i]->GetAllocatedString(
            MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &friendly_name, &name_len)) &&
        friendly_name != nullptr) {
      candidate_name = WideToUtf8(std::wstring(friendly_name, name_len));
      ::CoTaskMemFree(friendly_name);
    }

    std::string candidate_symlink;
    WCHAR* symlink = nullptr;
    UINT32 symlink_len = 0;
    if (SUCCEEDED(devices[i]->GetAllocatedString(
            MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &symlink,
            &symlink_len)) &&
        symlink != nullptr) {
      candidate_symlink = WideToUtf8(std::wstring(symlink, symlink_len));
      ::CoTaskMemFree(symlink);
    }

    int score = 0;
    if (candidate_name.find("Virtual") != std::string::npos ||
        candidate_name.find("virtual") != std::string::npos ||
        candidate_symlink.find("vcamdevapi") != std::string::npos) {
      score -= 200;
    } else {
      score += 50;
    }
    if (candidate_symlink.find("usb#") != std::string::npos ||
        candidate_symlink.find("USB#") != std::string::npos) {
      score += 40;
    }
    if (candidate_name.find("Integrated") != std::string::npos ||
        candidate_name.find("Front") != std::string::npos ||
        candidate_name.find("Webcam") != std::string::npos) {
      score += 30;
    }
    if (candidate_name.find("IR ") != std::string::npos ||
        candidate_name.find("Infrared") != std::string::npos) {
      score -= 40;
    }

    if (score > best_score) {
      best_score = score;
      best_index = static_cast<int>(i);
      best_name = candidate_name;
    }
  }

  result.activate = devices[best_index];
  result.device_name = best_name;
  result.detail = "Camera device " + result.device_name +
                  " discovered via Windows Media Foundation.";

  for (UINT32 i = 0; i < count; ++i) {
    if (devices[i] != nullptr) {
      devices[i]->Release();
    }
  }
  ::CoTaskMemFree(devices);
  return result;
}

bool IsSupportedVideoSubtype(const GUID& subtype) {
  return subtype == MFVideoFormat_NV12 || subtype == MFVideoFormat_YUY2 ||
         subtype == MFVideoFormat_RGB32 || subtype == MFVideoFormat_ARGB32 ||
         subtype == MFVideoFormat_RGB24;
}

int32_t DefaultStrideForSubtype(const GUID& subtype, UINT32 width) {
  if (subtype == MFVideoFormat_RGB32 || subtype == MFVideoFormat_ARGB32) {
    return static_cast<int32_t>(width * 4);
  }
  if (subtype == MFVideoFormat_RGB24) {
    return static_cast<int32_t>(width * 3);
  }
  if (subtype == MFVideoFormat_YUY2) {
    return static_cast<int32_t>(width * 2);
  }
  // NV12 and planar formats have 1 byte per Y sample in the luminance plane.
  return static_cast<int32_t>(width);
}

bool ExtractStreamFormatInfo(IMFMediaType* media_type, GUID* out_subtype,
                             UINT32* out_width, UINT32* out_height,
                             int32_t* out_stride) {
  if (media_type == nullptr) {
    return false;
  }
  GUID subtype = GUID_NULL;
  UINT32 width = 0;
  UINT32 height = 0;
  if (FAILED(media_type->GetGUID(MF_MT_SUBTYPE, &subtype)) ||
      FAILED(::MFGetAttributeSize(media_type, MF_MT_FRAME_SIZE, &width,
                                  &height)) ||
      width == 0 || height == 0) {
    return false;
  }

  UINT32 stride_u32 = 0;
  int32_t stride = DefaultStrideForSubtype(subtype, width);
  if (SUCCEEDED(media_type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride_u32))) {
    const int32_t candidate = static_cast<int32_t>(stride_u32);
    if (candidate != 0) {
      stride = candidate;
    }
  }

  *out_subtype = subtype;
  *out_width = width;
  *out_height = height;
  *out_stride = stride;
  return IsSupportedVideoSubtype(subtype);
}

bool ConfigureSourceReaderVideoFormat(IMFSourceReader* reader,
                                      GUID* out_subtype, UINT32* out_width,
                                      UINT32* out_height, int32_t* out_stride) {
  // 1. Scan native media types for a directly supported uncompressed format
  //    (preferring width <= 640 for low CPU usage).
  ComPtr<IMFMediaType> best_native_type;
  UINT32 best_pixels = UINT32_MAX;

  for (DWORD idx = 0;; ++idx) {
    ComPtr<IMFMediaType> native_type;
    HRESULT hr = reader->GetNativeMediaType(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), idx,
        native_type.GetAddressOf());
    if (hr == MF_E_NO_MORE_TYPES || FAILED(hr) || native_type == nullptr) {
      break;
    }

    GUID subtype = GUID_NULL;
    UINT32 w = 0;
    UINT32 h = 0;
    int32_t stride = 0;
    if (ExtractStreamFormatInfo(native_type.Get(), &subtype, &w, &h, &stride)) {
      const UINT32 pixels = w * h;
      // Prefer resolutions around 320x240..640x480; otherwise smallest available.
      const UINT32 score = (w >= 160 && w <= 640) ? pixels : (pixels + 10000000u);
      if (score < best_pixels) {
        best_pixels = score;
        best_native_type = native_type;
      }
    }
  }

  if (best_native_type != nullptr) {
    if (SUCCEEDED(reader->SetCurrentMediaType(
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
            best_native_type.Get()))) {
      ComPtr<IMFMediaType> current_type;
      if (SUCCEEDED(reader->GetCurrentMediaType(
              static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
              current_type.GetAddressOf())) &&
          ExtractStreamFormatInfo(current_type.Get(), out_subtype, out_width,
                                  out_height, out_stride)) {
        return true;
      }
    }
  }

  // 2. Ask Media Foundation video processor / decoder for NV12, RGB32, or YUY2.
  const GUID preferred_subtypes[] = {MFVideoFormat_NV12, MFVideoFormat_RGB32,
                                     MFVideoFormat_YUY2, MFVideoFormat_RGB24};
  for (const GUID& target_subtype : preferred_subtypes) {
    ComPtr<IMFMediaType> partial_type;
    if (SUCCEEDED(::MFCreateMediaType(partial_type.GetAddressOf())) &&
        partial_type != nullptr) {
      partial_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      partial_type->SetGUID(MF_MT_SUBTYPE, target_subtype);
      if (SUCCEEDED(reader->SetCurrentMediaType(
              static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
              partial_type.Get()))) {
        ComPtr<IMFMediaType> current_type;
        if (SUCCEEDED(reader->GetCurrentMediaType(
                static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
                current_type.GetAddressOf())) &&
            ExtractStreamFormatInfo(current_type.Get(), out_subtype, out_width,
                                    out_height, out_stride)) {
          return true;
        }
      }
    }
  }

  return false;
}

bool SampleFrameToGrayscaleGrid(const uint8_t* raw_data, size_t buffer_len,
                                const GUID& subtype, UINT32 src_width,
                                UINT32 src_height, int32_t stride,
                                int32_t grid_w, int32_t grid_h,
                                std::vector<float>* out_grid,
                                float* out_lum_sum) {
  if (raw_data == nullptr || src_width == 0 || src_height == 0 ||
      grid_w <= 0 || grid_h <= 0) {
    return false;
  }

  const size_t abs_stride = static_cast<size_t>(
      stride < 0 ? -stride : (stride > 0 ? stride : DefaultStrideForSubtype(subtype, src_width)));
  const bool bottom_up =
      (stride < 0) &&
      (subtype == MFVideoFormat_RGB32 || subtype == MFVideoFormat_ARGB32 ||
       subtype == MFVideoFormat_RGB24);

  const size_t required_bytes = abs_stride * static_cast<size_t>(src_height);
  if (buffer_len < required_bytes) {
    return false;
  }

  const size_t count = static_cast<size_t>(grid_w * grid_h);
  out_grid->assign(count, 0.0f);
  float lum_sum = 0.0f;

  for (int32_t gy = 0; gy < grid_h; ++gy) {
    UINT32 sy = (static_cast<UINT32>(gy) * src_height) /
                static_cast<UINT32>(grid_h);
    if (bottom_up) {
      sy = (src_height - 1) - sy;
    }
    const size_t row_offset = static_cast<size_t>(sy) * abs_stride;

    for (int32_t gx = 0; gx < grid_w; ++gx) {
      const UINT32 sx = (static_cast<UINT32>(gx) * src_width) /
                        static_cast<UINT32>(grid_w);
      float y_val = 0.0f;

      if (subtype == MFVideoFormat_NV12) {
        const size_t offset = row_offset + static_cast<size_t>(sx);
        if (offset < buffer_len) {
          y_val = static_cast<float>(raw_data[offset]);
        }
      } else if (subtype == MFVideoFormat_YUY2) {
        const size_t offset = row_offset + (static_cast<size_t>(sx) * 2);
        if (offset < buffer_len) {
          y_val = static_cast<float>(raw_data[offset]);
        }
      } else if (subtype == MFVideoFormat_RGB32 ||
                 subtype == MFVideoFormat_ARGB32) {
        const size_t offset = row_offset + (static_cast<size_t>(sx) * 4);
        if (offset + 2 < buffer_len) {
          const int32_t b = static_cast<int32_t>(raw_data[offset]);
          const int32_t g = static_cast<int32_t>(raw_data[offset + 1]);
          const int32_t r = static_cast<int32_t>(raw_data[offset + 2]);
          y_val = static_cast<float>((77 * r + 150 * g + 29 * b) >> 8);
        }
      } else if (subtype == MFVideoFormat_RGB24) {
        const size_t offset = row_offset + (static_cast<size_t>(sx) * 3);
        if (offset + 2 < buffer_len) {
          const int32_t b = static_cast<int32_t>(raw_data[offset]);
          const int32_t g = static_cast<int32_t>(raw_data[offset + 1]);
          const int32_t r = static_cast<int32_t>(raw_data[offset + 2]);
          y_val = static_cast<float>((77 * r + 150 * g + 29 * b) >> 8);
        }
      }

      const size_t idx = static_cast<size_t>(gy * grid_w + gx);
      (*out_grid)[idx] = y_val;
      lum_sum += y_val;
    }
  }

  *out_lum_sum = lum_sum;
  return true;
}

class WindowsCameraMotionBridge {
 public:
  WindowsCameraMotionBridge(flutter::BinaryMessenger* messenger,
                            std::shared_ptr<MainThreadDispatcher> dispatcher)
      : dispatcher_(std::move(dispatcher)) {
    HRESULT hr = ::MFStartup(MF_VERSION);
    mf_initialized_ = SUCCEEDED(hr);

    method_channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            messenger, "dev.watsafe/windows_camera",
            &flutter::StandardMethodCodec::GetInstance());
    event_channel_ =
        std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
            messenger, "dev.watsafe/windows_camera_events",
            &flutter::StandardMethodCodec::GetInstance());

    method_channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) { HandleMethodCall(call, std::move(result)); });

    auto handler = std::make_unique<
        flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
        [this](const flutter::EncodableValue* arguments,
               std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                   events)
            -> std::unique_ptr<
                flutter::StreamHandlerError<flutter::EncodableValue>> {
          event_sink_ = std::move(events);
          return nullptr;
        },
        [this](const flutter::EncodableValue* arguments)
            -> std::unique_ptr<
                flutter::StreamHandlerError<flutter::EncodableValue>> {
          event_sink_.reset();
          return nullptr;
        });
    event_channel_->SetStreamHandler(std::move(handler));
  }

  ~WindowsCameraMotionBridge() {
    StopCapture();
    if (mf_initialized_) {
      ::MFShutdown();
      mf_initialized_ = false;
    }
  }

  void OnSystemSuspend() {
    std::string session_id;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      session_id = active_session_id_;
    }
    if (!session_id.empty()) {
      EmitEvent(flutter::EncodableMap{
          {flutter::EncodableValue("sessionId"),
           flutter::EncodableValue(session_id)},
          {flutter::EncodableValue("eventType"),
           flutter::EncodableValue("lifecyclePaused")},
          {flutter::EncodableValue("summary"),
           flutter::EncodableValue(
               "Windows system entering sleep; webcam capture paused.")},
          {flutter::EncodableValue("timestampMs"),
           flutter::EncodableValue(CurrentTimeMillis())},
      });
    }
  }

  void OnSystemResume() {
    std::string session_id;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      session_id = active_session_id_;
    }
    if (!session_id.empty()) {
      EmitEvent(flutter::EncodableMap{
          {flutter::EncodableValue("sessionId"),
           flutter::EncodableValue(session_id)},
          {flutter::EncodableValue("eventType"),
           flutter::EncodableValue("lifecycleResumed")},
          {flutter::EncodableValue("summary"),
           flutter::EncodableValue(
               "Windows system woke from sleep; webcam monitoring resumed.")},
          {flutter::EncodableValue("timestampMs"),
           flutter::EncodableValue(CurrentTimeMillis())},
      });
    }
  }

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const std::string& method = call.method_name();
    const auto* args = GetArgsMap(call.arguments());

    if (method == "checkCapability") {
      const CameraDeviceProbe probe = ProbeWindowsCamera();
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("hasCameraHardware"),
           flutter::EncodableValue(probe.has_hardware)},
          {flutter::EncodableValue("deviceName"),
           flutter::EncodableValue(probe.device_name)},
          {flutter::EncodableValue("permissionStatus"),
           flutter::EncodableValue(probe.permission_status)},
          {flutter::EncodableValue("detail"),
           flutter::EncodableValue(probe.detail)},
      }));
      return;
    }

    if (method == "requestPermission") {
      std::string perm = QueryWindowsCameraPermissionStatus();
      if (perm == "denied") {
        ::ShellExecuteW(nullptr, L"open", L"ms-settings:privacy-webcam",
                        nullptr, nullptr, SW_SHOWNORMAL);
      }
      result->Success(flutter::EncodableValue(perm));
      return;
    }

    if (method == "startMonitoring") {
      StartMonitoring(args, std::move(result));
      return;
    }

    if (method == "updateSensitivity") {
      const double threshold =
          std::clamp(GetDoubleArg(args, "motionScoreThreshold", 0.095), 0.02, 0.50);
      motion_threshold_.store(threshold);
      result->Success();
      return;
    }

    if (method == "stopMonitoring") {
      StopCapture();
      result->Success();
      return;
    }

    result->NotImplemented();
  }

  void StartMonitoring(
      const flutter::EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    StopCapture();

    const std::string session_id =
        GetStringArg(args, "sessionId", "session_default");
    const double threshold =
        std::clamp(GetDoubleArg(args, "motionScoreThreshold", 0.095), 0.02, 0.50);
    const int32_t calibration_ms =
        std::max<int32_t>(500, GetIntArg(args, "calibrationDurationMs", 1500));
    const int32_t persistence_frames =
        std::max<int32_t>(1, GetIntArg(args, "persistenceFramesRequired", 3));
    const int32_t grid_w =
        std::clamp(GetIntArg(args, "downsampleWidth", 64), 16, 160);
    const int32_t grid_h =
        std::clamp(GetIntArg(args, "downsampleHeight", 48), 12, 120);

    CameraDeviceProbe probe = ProbeWindowsCamera();
    if (probe.permission_status != "granted") {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("started"), flutter::EncodableValue(false)},
          {flutter::EncodableValue("message"),
           flutter::EncodableValue(
               "Windows camera access is disabled in Privacy Settings.")},
          {flutter::EncodableValue("errorCode"),
           flutter::EncodableValue("PERMISSION_NOT_GRANTED")},
      }));
      return;
    }

    if (!probe.has_hardware || probe.activate == nullptr) {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("started"), flutter::EncodableValue(false)},
          {flutter::EncodableValue("message"),
           flutter::EncodableValue("No Windows camera hardware found.")},
          {flutter::EncodableValue("errorCode"),
           flutter::EncodableValue("NO_CAMERA_HARDWARE")},
      }));
      return;
    }

    // Activate the media source and configure IMFSourceReader before returning
    // so any hardware/sharing error is reported immediately.
    ComPtr<IMFMediaSource> media_source;
    HRESULT hr = probe.activate->ActivateObject(
        IID_PPV_ARGS(media_source.GetAddressOf()));
    if (FAILED(hr) || media_source == nullptr) {
      const bool access_denied = (hr == E_ACCESSDENIED);
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("started"), flutter::EncodableValue(false)},
          {flutter::EncodableValue("message"),
           flutter::EncodableValue(
               access_denied
                   ? "Windows blocked camera access. Check Settings > Privacy & security > Camera."
                   : "Failed to activate Windows camera media source (camera may be in use).")},
          {flutter::EncodableValue("errorCode"),
           flutter::EncodableValue(access_denied ? "PERMISSION_DENIED"
                                                 : "SOURCE_ACTIVATE_FAILED")},
      }));
      return;
    }

    ComPtr<IMFAttributes> reader_attrs;
    ::MFCreateAttributes(reader_attrs.GetAddressOf(), 2);
    if (reader_attrs != nullptr) {
      reader_attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    }

    ComPtr<IMFSourceReader> reader;
    hr = ::MFCreateSourceReaderFromMediaSource(
        media_source.Get(), reader_attrs.Get(), reader.GetAddressOf());
    if (FAILED(hr) || reader == nullptr) {
      media_source->Shutdown();
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("started"), flutter::EncodableValue(false)},
          {flutter::EncodableValue("message"),
           flutter::EncodableValue(
               "Failed to create Media Foundation source reader for camera.")},
          {flutter::EncodableValue("errorCode"),
           flutter::EncodableValue("READER_CREATE_FAILED")},
      }));
      return;
    }

    GUID subtype = GUID_NULL;
    UINT32 frame_width = 0;
    UINT32 frame_height = 0;
    int32_t stride = 0;
    if (!ConfigureSourceReaderVideoFormat(reader.Get(), &subtype, &frame_width,
                                          &frame_height, &stride)) {
      reader.Reset();
      media_source->Shutdown();
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("started"), flutter::EncodableValue(false)},
          {flutter::EncodableValue("message"),
           flutter::EncodableValue(
               "Could not negotiate a compatible video format with the camera.")},
          {flutter::EncodableValue("errorCode"),
           flutter::EncodableValue("UNSUPPORTED_VIDEO_FORMAT")},
      }));
      return;
    }

    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      active_session_id_ = session_id;
    }
    motion_threshold_.store(threshold);
    running_.store(true);

    const std::string device_name = probe.device_name;
    EmitEvent(flutter::EncodableMap{
        {flutter::EncodableValue("sessionId"),
         flutter::EncodableValue(session_id)},
        {flutter::EncodableValue("eventType"),
         flutter::EncodableValue("calibrationStarted")},
        {flutter::EncodableValue("summary"),
         flutter::EncodableValue("Calibrating baseline scene on " +
                                 device_name + "...")},
        {flutter::EncodableValue("threshold"),
         flutter::EncodableValue(threshold)},
        {flutter::EncodableValue("timestampMs"),
         flutter::EncodableValue(CurrentTimeMillis())},
    });

    worker_thread_ = std::thread([this, session_id, calibration_ms,
                                  persistence_frames, grid_w, grid_h,
                                  media_source, reader, subtype, frame_width,
                                  frame_height, stride]() mutable {
      RunCameraLoop(session_id, calibration_ms, persistence_frames, grid_w,
                    grid_h, std::move(media_source), std::move(reader), subtype,
                    frame_width, frame_height, stride);
    });

    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("started"), flutter::EncodableValue(true)},
        {flutter::EncodableValue("message"),
         flutter::EncodableValue("Monitoring active on " + device_name + ".")},
    }));
  }

  void RunCameraLoop(const std::string& session_id, int32_t calibration_ms,
                     int32_t persistence_frames, int32_t grid_w,
                     int32_t grid_h, ComPtr<IMFMediaSource> media_source,
                     ComPtr<IMFSourceReader> reader, GUID subtype,
                     UINT32 src_width, UINT32 src_height, int32_t stride) {
    ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    const int64_t session_start_ms = CurrentTimeMillis();
    int64_t last_frame_processed_ms = 0;
    bool is_calibration_done = false;
    std::vector<float> reference_grid;
    std::vector<float> current_grid;
    int32_t consecutive_above_threshold = 0;
    int32_t consecutive_poor_input = 0;
    bool is_input_degraded = false;
    int32_t processed_frame_count = 0;

    while (running_.load()) {
      DWORD stream_index = 0;
      DWORD stream_flags = 0;
      LONGLONG sample_timestamp = 0;
      ComPtr<IMFSample> sample;

      HRESULT hr = reader->ReadSample(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0,
          &stream_index, &stream_flags, &sample_timestamp,
          sample.GetAddressOf());

      if (!running_.load()) {
        break;
      }

      if (FAILED(hr) || (stream_flags & MF_SOURCE_READERF_ERROR)) {
        EmitEvent(flutter::EncodableMap{
            {flutter::EncodableValue("sessionId"),
             flutter::EncodableValue(session_id)},
            {flutter::EncodableValue("eventType"),
             flutter::EncodableValue("detectorFailed")},
            {flutter::EncodableValue("summary"),
             flutter::EncodableValue(
                 "Windows webcam stream error or device disconnected.")},
            {flutter::EncodableValue("errorCode"),
             flutter::EncodableValue("MF_CAPTURE_ERROR")},
            {flutter::EncodableValue("timestampMs"),
             flutter::EncodableValue(CurrentTimeMillis())},
        });
        break;
      }

      if (stream_flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
        ComPtr<IMFMediaType> updated_type;
        if (SUCCEEDED(reader->GetCurrentMediaType(
                static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
                updated_type.GetAddressOf()))) {
          ExtractStreamFormatInfo(updated_type.Get(), &subtype, &src_width,
                                  &src_height, &stride);
        }
      }

      if (sample == nullptr) {
        continue;
      }

      const int64_t now_ms = CurrentTimeMillis();
      // Throttle to ~8 frames per second off the UI thread.
      if ((now_ms - last_frame_processed_ms) < 120) {
        continue;
      }
      last_frame_processed_ms = now_ms;

      ComPtr<IMFMediaBuffer> buffer;
      if (FAILED(sample->ConvertToContiguousBuffer(buffer.GetAddressOf())) ||
          buffer == nullptr) {
        continue;
      }

      BYTE* raw_ptr = nullptr;
      DWORD max_len = 0;
      DWORD cur_len = 0;
      if (FAILED(buffer->Lock(&raw_ptr, &max_len, &cur_len)) ||
          raw_ptr == nullptr || cur_len == 0) {
        continue;
      }

      float lum_sum = 0.0f;
      const bool sampled = SampleFrameToGrayscaleGrid(
          raw_ptr, static_cast<size_t>(cur_len), subtype, src_width, src_height,
          stride, grid_w, grid_h, &current_grid, &lum_sum);
      buffer->Unlock();

      if (!sampled || current_grid.empty()) {
        continue;
      }

      const size_t count = current_grid.size();
      const float mean_lum_255 = lum_sum / static_cast<float>(count);
      const double normalized_luminance =
          static_cast<double>(mean_lum_255 / 255.0f);

      float variance_sum = 0.0f;
      for (float val : current_grid) {
        variance_sum += std::abs(val - mean_lum_255);
      }
      const double normalized_deviation =
          static_cast<double>((variance_sum / static_cast<float>(count)) / 255.0f);

      processed_frame_count += 1;
      const double active_threshold = motion_threshold_.load();

      // Check for covered lens or pitch-black poor input
      if (normalized_luminance < 0.025 || normalized_deviation < 0.007) {
        consecutive_poor_input += 1;
        if (consecutive_poor_input >= 8 && !is_input_degraded) {
          is_input_degraded = true;
          const int32_t pct =
              static_cast<int32_t>(std::lround(normalized_luminance * 100.0));
          EmitEvent(flutter::EncodableMap{
              {flutter::EncodableValue("sessionId"),
               flutter::EncodableValue(session_id)},
              {flutter::EncodableValue("eventType"),
               flutter::EncodableValue("poorInputWarning")},
              {flutter::EncodableValue("summary"),
               flutter::EncodableValue(
                   "Low light or covered camera lens detected (brightness " +
                   std::to_string(pct) +
                   "%). Scene-motion sensitivity is degraded.")},
              {flutter::EncodableValue("averageLuminance"),
               flutter::EncodableValue(normalized_luminance)},
              {flutter::EncodableValue("threshold"),
               flutter::EncodableValue(active_threshold)},
              {flutter::EncodableValue("timestampMs"),
               flutter::EncodableValue(now_ms)},
          });
        }
      } else if (normalized_luminance >= 0.04 && normalized_deviation >= 0.012) {
        consecutive_poor_input = 0;
        if (is_input_degraded) {
          is_input_degraded = false;
          EmitEvent(flutter::EncodableMap{
              {flutter::EncodableValue("sessionId"),
               flutter::EncodableValue(session_id)},
              {flutter::EncodableValue("eventType"),
               flutter::EncodableValue("inputRecovered")},
              {flutter::EncodableValue("summary"),
               flutter::EncodableValue(
                   "Camera lighting and scene contrast restored.")},
              {flutter::EncodableValue("averageLuminance"),
               flutter::EncodableValue(normalized_luminance)},
              {flutter::EncodableValue("threshold"),
               flutter::EncodableValue(active_threshold)},
              {flutter::EncodableValue("timestampMs"),
               flutter::EncodableValue(now_ms)},
          });
        }
      }

      if (reference_grid.size() != count) {
        reference_grid = current_grid;
        continue;
      }

      const int64_t elapsed_ms = now_ms - session_start_ms;
      if (!is_calibration_done) {
        for (size_t i = 0; i < count; ++i) {
          reference_grid[i] =
              (0.65f * reference_grid[i]) + (0.35f * current_grid[i]);
        }
        if (elapsed_ms >= calibration_ms && processed_frame_count >= 4) {
          is_calibration_done = true;
          EmitEvent(flutter::EncodableMap{
              {flutter::EncodableValue("sessionId"),
               flutter::EncodableValue(session_id)},
              {flutter::EncodableValue("eventType"),
               flutter::EncodableValue("calibrationCompleted")},
              {flutter::EncodableValue("summary"),
               flutter::EncodableValue(
                   "Scene baseline calibrated. Active scene-motion filtering enabled.")},
              {flutter::EncodableValue("motionScore"),
               flutter::EncodableValue(0.0)},
              {flutter::EncodableValue("threshold"),
               flutter::EncodableValue(active_threshold)},
              {flutter::EncodableValue("averageLuminance"),
               flutter::EncodableValue(normalized_luminance)},
              {flutter::EncodableValue("consecutiveFrames"),
               flutter::EncodableValue(static_cast<int32_t>(0))},
              {flutter::EncodableValue("timestampMs"),
               flutter::EncodableValue(now_ms)},
          });
        }
        continue;
      }

      float ref_lum_sum = 0.0f;
      for (size_t i = 0; i < count; ++i) {
        ref_lum_sum += reference_grid[i];
      }
      const float ref_mean_255 = ref_lum_sum / static_cast<float>(count);
      const float dc_shift =
          std::clamp(mean_lum_255 - ref_mean_255, -45.0f, 45.0f);

      constexpr int32_t kBlocksX = 4;
      constexpr int32_t kBlocksY = 4;
      constexpr int32_t kTotalBlocks = kBlocksX * kBlocksY;
      float block_diff_sum[kTotalBlocks] = {0.0f};
      int32_t block_pixel_count[kTotalBlocks] = {0};

      float raw_diff_sum = 0.0f;
      float struct_diff_sum = 0.0f;
      for (int32_t gy = 0; gy < grid_h; ++gy) {
        const int32_t by =
            std::min(kBlocksY - 1, (gy * kBlocksY) / std::max(1, grid_h));
        for (int32_t gx = 0; gx < grid_w; ++gx) {
          const int32_t bx =
              std::min(kBlocksX - 1, (gx * kBlocksX) / std::max(1, grid_w));
          const int32_t block_idx = by * kBlocksX + bx;
          const size_t i =
              static_cast<size_t>(gy) * static_cast<size_t>(grid_w) +
              static_cast<size_t>(gx);

          const float signed_diff = current_grid[i] - reference_grid[i];
          const float raw_delta = std::abs(signed_diff);
          const float struct_delta =
              std::abs(signed_diff - (0.75f * dc_shift));

          raw_diff_sum += raw_delta;
          struct_diff_sum += struct_delta;
          block_diff_sum[block_idx] += struct_delta;
          block_pixel_count[block_idx] += 1;

          reference_grid[i] =
              (0.92f * reference_grid[i]) + (0.08f * current_grid[i]);
        }
      }

      const double block_activity_threshold =
          std::max(0.018, active_threshold * 0.45);
      int32_t active_blocks = 0;
      for (int32_t b = 0; b < kTotalBlocks; ++b) {
        if (block_pixel_count[b] > 0) {
          const double block_score = static_cast<double>(
              block_diff_sum[b] /
              static_cast<float>(block_pixel_count[b] * 255));
          if (block_score >= block_activity_threshold) {
            active_blocks += 1;
          }
        }
      }

      const double raw_motion_score =
          static_cast<double>(raw_diff_sum / static_cast<float>(count * 255));
      const double struct_motion_score =
          static_cast<double>(struct_diff_sum / static_cast<float>(count * 255));

      double spatial_weight = 1.0;
      if (active_blocks >= 7 || raw_motion_score >= (active_threshold * 1.8)) {
        spatial_weight = 1.0;
      } else if (active_blocks <= 3) {
        spatial_weight = 0.35;
      } else {
        spatial_weight =
            0.35 + (static_cast<double>(active_blocks - 3) * (0.65 / 4.0));
      }

      const double motion_score = struct_motion_score * spatial_weight;
      if (motion_score >= active_threshold) {
        consecutive_above_threshold += 1;
      } else {
        consecutive_above_threshold = 0;
      }

      if (consecutive_above_threshold >= persistence_frames) {
        char summary_buf[180];
        std::snprintf(
            summary_buf, sizeof(summary_buf),
            "Sustained scene motion detected (score %.3f >= threshold %.3f across %d frames)",
            motion_score, active_threshold, consecutive_above_threshold);
        EmitEvent(flutter::EncodableMap{
            {flutter::EncodableValue("sessionId"),
             flutter::EncodableValue(session_id)},
            {flutter::EncodableValue("eventType"),
             flutter::EncodableValue("motionTriggered")},
            {flutter::EncodableValue("summary"),
             flutter::EncodableValue(std::string(summary_buf))},
            {flutter::EncodableValue("motionScore"),
             flutter::EncodableValue(motion_score)},
            {flutter::EncodableValue("threshold"),
             flutter::EncodableValue(active_threshold)},
            {flutter::EncodableValue("averageLuminance"),
             flutter::EncodableValue(normalized_luminance)},
            {flutter::EncodableValue("consecutiveFrames"),
             flutter::EncodableValue(consecutive_above_threshold)},
            {flutter::EncodableValue("timestampMs"),
             flutter::EncodableValue(now_ms)},
        });
      } else if (processed_frame_count % 3 == 0) {
        char summary_buf[140];
        std::snprintf(summary_buf, sizeof(summary_buf),
                      "Scene motion score %.3f (threshold %.3f)", motion_score,
                      active_threshold);
        EmitEvent(flutter::EncodableMap{
            {flutter::EncodableValue("sessionId"),
             flutter::EncodableValue(session_id)},
            {flutter::EncodableValue("eventType"),
             flutter::EncodableValue("telemetryFrame")},
            {flutter::EncodableValue("summary"),
             flutter::EncodableValue(std::string(summary_buf))},
            {flutter::EncodableValue("motionScore"),
             flutter::EncodableValue(motion_score)},
            {flutter::EncodableValue("threshold"),
             flutter::EncodableValue(active_threshold)},
            {flutter::EncodableValue("averageLuminance"),
             flutter::EncodableValue(normalized_luminance)},
            {flutter::EncodableValue("consecutiveFrames"),
             flutter::EncodableValue(consecutive_above_threshold)},
            {flutter::EncodableValue("timestampMs"),
             flutter::EncodableValue(now_ms)},
        });
      }
    }

    reader.Reset();
    if (media_source != nullptr) {
      media_source->Shutdown();
      media_source.Reset();
    }
    ::CoUninitialize();
  }

  void StopCapture() {
    running_.store(false);
    if (worker_thread_.joinable()) {
      worker_thread_.join();
    }
    std::lock_guard<std::mutex> lock(state_mutex_);
    active_session_id_.clear();
  }

  void EmitEvent(flutter::EncodableMap payload) {
    dispatcher_->Post([this, payload = std::move(payload)]() {
      if (event_sink_) {
        event_sink_->Success(flutter::EncodableValue(payload));
      }
    });
  }

  bool mf_initialized_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::shared_ptr<MainThreadDispatcher> dispatcher_;

  std::mutex state_mutex_;
  std::string active_session_id_;
  std::atomic<bool> running_{false};
  std::atomic<double> motion_threshold_{0.095};
  std::thread worker_thread_;
};

}  // namespace

// ============================================================================
// Container owning all WATSafe Windows native bridges
// ============================================================================

class WindowsPlatformBridges {
 public:
  WindowsPlatformBridges(HWND hwnd, flutter::BinaryMessenger* messenger)
      : dispatcher_(std::make_shared<MainThreadDispatcher>(hwnd)),
        audio_bridge_(messenger, dispatcher_),
        secure_storage_bridge_(messenger),
        accelerometer_bridge_(messenger, dispatcher_),
        camera_bridge_(messenger, dispatcher_) {}

  ~WindowsPlatformBridges() { dispatcher_->Shutdown(); }

  void DrainMainThreadTasks() { dispatcher_->DrainTasks(); }

  void OnPowerBroadcast(WPARAM wparam) {
    if (wparam == PBT_APMSUSPEND) {
      accelerometer_bridge_.OnSystemSuspend();
      camera_bridge_.OnSystemSuspend();
    } else if (wparam == PBT_APMRESUMEAUTOMATIC ||
               wparam == PBT_APMRESUMESUSPEND) {
      accelerometer_bridge_.OnSystemResume();
      camera_bridge_.OnSystemResume();
    }
  }

 private:
  std::shared_ptr<MainThreadDispatcher> dispatcher_;
  WindowsAudioAlarmBridge audio_bridge_;
  WindowsSecureStorageBridge secure_storage_bridge_;
  WindowsAccelerometerBridge accelerometer_bridge_;
  WindowsCameraMotionBridge camera_bridge_;
};

// ============================================================================
// FlutterWindow lifecycle & message handling
// ============================================================================

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  bridges_ = std::make_unique<WindowsPlatformBridges>(
      GetHandle(), flutter_controller_->engine()->messenger());

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  this->Show();
  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (bridges_) {
    bridges_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    case kWmFlutterBridgeCallback:
      if (bridges_) {
        bridges_->DrainMainThreadTasks();
      }
      return 0;

    case WM_POWERBROADCAST:
      if (bridges_) {
        bridges_->OnPowerBroadcast(wparam);
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
