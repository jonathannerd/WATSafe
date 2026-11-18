#include "flutter_window.h"

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <commdlg.h>
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

    if (method == "pickCustomAudioFile") {
      wchar_t file_buf[MAX_PATH] = {0};
      OPENFILENAMEW ofn;
      std::memset(&ofn, 0, sizeof(ofn));
      ofn.lStructSize = sizeof(ofn);
      ofn.hwndOwner = nullptr;
      ofn.lpstrFile = file_buf;
      ofn.nMaxFile = MAX_PATH;
      ofn.lpstrFilter = L"WAV Audio Files (*.wav)\0*.wav\0All Files (*.*)\0*.*\0";
      ofn.nFilterIndex = 1;
      ofn.Flags = OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST | OFN_NOCHANGEDIR;
      if (::GetOpenFileNameW(&ofn)) {
        result->Success(flutter::EncodableValue(WideToUtf8(file_buf)));
      } else {
        result->Success(flutter::EncodableValue());
      }
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

    // Locate the "fmt " and "data" subchunks dynamically in case the WAV file
    // contains extra metadata/LIST chunks before "data".
    size_t data_offset = 44;
    size_t data_len = scaled_wav_bytes_.size() - 44;
    uint16_t bits_per_sample = 16;

    size_t pos = 12;
    while (pos + 8 <= scaled_wav_bytes_.size()) {
      const uint32_t chunk_size =
          static_cast<uint32_t>(scaled_wav_bytes_[pos + 4]) |
          (static_cast<uint32_t>(scaled_wav_bytes_[pos + 5]) << 8) |
          (static_cast<uint32_t>(scaled_wav_bytes_[pos + 6]) << 16) |
          (static_cast<uint32_t>(scaled_wav_bytes_[pos + 7]) << 24);
      if (std::memcmp(&scaled_wav_bytes_[pos], "fmt ", 4) == 0 &&
          pos + 8 + 16 <= scaled_wav_bytes_.size()) {
        bits_per_sample =
            static_cast<uint16_t>(scaled_wav_bytes_[pos + 22]) |
            (static_cast<uint16_t>(scaled_wav_bytes_[pos + 23]) << 8);
      } else if (std::memcmp(&scaled_wav_bytes_[pos], "data", 4) == 0) {
        data_offset = pos + 8;
        data_len = std::min<size_t>(chunk_size,
                                    scaled_wav_bytes_.size() - data_offset);
        break;
      }
      pos += 8 + chunk_size + (chunk_size & 1);
    }

    const double clamped = std::clamp(volume, 0.0, 1.0);
    const size_t end_offset =
        std::min(scaled_wav_bytes_.size(), data_offset + data_len);

    if (bits_per_sample == 16) {
      for (size_t i = data_offset; i + 1 < end_offset; i += 2) {
        int16_t sample = static_cast<int16_t>(
            static_cast<uint16_t>(scaled_wav_bytes_[i]) |
            (static_cast<uint16_t>(scaled_wav_bytes_[i + 1]) << 8));
        int32_t scaled = static_cast<int32_t>(std::lround(sample * clamped));
        scaled = std::clamp(scaled, -32768, 32767);
        const uint16_t encoded =
            static_cast<uint16_t>(static_cast<int16_t>(scaled));
        scaled_wav_bytes_[i] = static_cast<uint8_t>(encoded & 0xFF);
        scaled_wav_bytes_[i + 1] =
            static_cast<uint8_t>((encoded >> 8) & 0xFF);
      }
    } else if (bits_per_sample == 8) {
      for (size_t i = data_offset; i < end_offset; ++i) {
        int32_t centered = static_cast<int32_t>(scaled_wav_bytes_[i]) - 128;
        int32_t scaled = static_cast<int32_t>(std::lround(centered * clamped));
        scaled_wav_bytes_[i] =
            static_cast<uint8_t>(std::clamp(scaled + 128, 0, 255));
      }
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

  void OnSystemSuspend(bool protection_armed) {
    std::string session_id;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      session_id = active_session_id_;
      if (!session_id.empty()) {
        paused_session_id_ = session_id;
      }
    }
    if (!session_id.empty()) {
      StopCapture();
      if (!protection_armed) {
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
  }

  void OnSystemResume() {
    std::string session_id;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      session_id =
          !active_session_id_.empty() ? active_session_id_ : paused_session_id_;
      paused_session_id_.clear();
    }
    if (!session_id.empty()) {
      EmitEvent(flutter::EncodableMap{
          {flutter::EncodableValue("sessionId"),
           flutter::EncodableValue(session_id)},
          {flutter::EncodableValue("eventType"),
           flutter::EncodableValue("lifecycleResumed")},
          {flutter::EncodableValue("summary"),
           flutter::EncodableValue(
               "Windows system woke from sleep; accelerometer monitoring ready to resume.")},
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
      paused_session_id_.clear();
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
  std::string paused_session_id_;
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
  return subtype == MFVideoFormat_NV12 || subtype == MFVideoFormat_I420 ||
         subtype == MFVideoFormat_IYUV || subtype == MFVideoFormat_YUY2 ||
         subtype == MFVideoFormat_UYVY || subtype == MFVideoFormat_RGB32 ||
         subtype == MFVideoFormat_ARGB32 || subtype == MFVideoFormat_RGB24;
}

int32_t DefaultStrideForSubtype(const GUID& subtype, UINT32 width) {
  if (subtype == MFVideoFormat_RGB32 || subtype == MFVideoFormat_ARGB32) {
    return static_cast<int32_t>(width * 4u);
  }
  if (subtype == MFVideoFormat_RGB24) {
    return static_cast<int32_t>(width * 3u);
  }
  if (subtype == MFVideoFormat_YUY2 || subtype == MFVideoFormat_UYVY) {
    return static_cast<int32_t>(width * 2u);
  }
  // NV12, I420, and IYUV have 1 byte per Y sample in the luminance plane.
  return static_cast<int32_t>(width);
}

size_t ContiguousFrameBytesForSubtype(const GUID& subtype, UINT32 width,
                                      UINT32 height) {
  if (subtype == MFVideoFormat_NV12 || subtype == MFVideoFormat_I420 ||
      subtype == MFVideoFormat_IYUV) {
    const size_t w = static_cast<size_t>(width);
    const size_t h = static_cast<size_t>(height);
    const size_t uv_w = (w + 1u) / 2u;
    const size_t uv_h = (h + 1u) / 2u;
    return (w * h) + (uv_w * uv_h * 2u);
  }
  return static_cast<size_t>(DefaultStrideForSubtype(subtype, width)) *
         static_cast<size_t>(height);
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
      const UINT32 score =
          (w >= 160 && w <= 640) ? pixels : (pixels + 10000000u);
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

  // 2. Ask Media Foundation video processor / MJPEG decoder for a supported
  //    uncompressed output format.
  const GUID preferred_subtypes[] = {
      MFVideoFormat_NV12,  MFVideoFormat_YUY2,  MFVideoFormat_I420,
      MFVideoFormat_RGB32, MFVideoFormat_UYVY,  MFVideoFormat_RGB24};
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

float SamplePixelLuminanceFromRow(const uint8_t* row_ptr, size_t max_row_bytes,
                                  const GUID& subtype, UINT32 sx) {
  if (subtype == MFVideoFormat_NV12 || subtype == MFVideoFormat_I420 ||
      subtype == MFVideoFormat_IYUV) {
    const size_t offset = static_cast<size_t>(sx);
    if (offset < max_row_bytes) {
      return static_cast<float>(row_ptr[offset]);
    }
  } else if (subtype == MFVideoFormat_YUY2) {
    const size_t offset = static_cast<size_t>(sx) * 2u;
    if (offset < max_row_bytes) {
      return static_cast<float>(row_ptr[offset]);
    }
  } else if (subtype == MFVideoFormat_UYVY) {
    const size_t offset = (static_cast<size_t>(sx) * 2u) + 1u;
    if (offset < max_row_bytes) {
      return static_cast<float>(row_ptr[offset]);
    }
  } else if (subtype == MFVideoFormat_RGB32 ||
             subtype == MFVideoFormat_ARGB32) {
    const size_t offset = static_cast<size_t>(sx) * 4u;
    if (offset + 2u < max_row_bytes) {
      const int32_t b = static_cast<int32_t>(row_ptr[offset]);
      const int32_t g = static_cast<int32_t>(row_ptr[offset + 1u]);
      const int32_t r = static_cast<int32_t>(row_ptr[offset + 2u]);
      return static_cast<float>((77 * r + 150 * g + 29 * b) >> 8);
    }
  } else if (subtype == MFVideoFormat_RGB24) {
    const size_t offset = static_cast<size_t>(sx) * 3u;
    if (offset + 2u < max_row_bytes) {
      const int32_t b = static_cast<int32_t>(row_ptr[offset]);
      const int32_t g = static_cast<int32_t>(row_ptr[offset + 1u]);
      const int32_t r = static_cast<int32_t>(row_ptr[offset + 2u]);
      return static_cast<float>((77 * r + 150 * g + 29 * b) >> 8);
    }
  }
  return 0.0f;
}

// Samples a 2D surface locked via IMF2DBuffer::Lock2D where scanline0 already
// points to the top visual row and pitch may be positive or negative.
bool Sample2DSurfaceToGrayscaleGrid(const uint8_t* scanline0, LONG pitch,
                                    const GUID& subtype, UINT32 src_width,
                                    UINT32 src_height, int32_t grid_w,
                                    int32_t grid_h,
                                    std::vector<float>* out_grid,
                                    float* out_lum_sum) {
  if (scanline0 == nullptr || pitch == 0 || src_width == 0 || src_height == 0 ||
      grid_w <= 0 || grid_h <= 0) {
    return false;
  }
  const size_t min_stride =
      static_cast<size_t>(DefaultStrideForSubtype(subtype, src_width));
  const size_t abs_pitch =
      static_cast<size_t>(pitch < 0 ? -pitch : pitch);
  if (abs_pitch < min_stride) {
    return false;
  }

  const size_t count =
      static_cast<size_t>(grid_w) * static_cast<size_t>(grid_h);
  out_grid->assign(count, 0.0f);
  float lum_sum = 0.0f;

  for (int32_t gy = 0; gy < grid_h; ++gy) {
    const UINT32 sy =
        (static_cast<UINT32>(gy) * src_height) / static_cast<UINT32>(grid_h);
    const uint8_t* row_ptr =
        scanline0 +
        (static_cast<ptrdiff_t>(sy) * static_cast<ptrdiff_t>(pitch));
    for (int32_t gx = 0; gx < grid_w; ++gx) {
      const UINT32 sx =
          (static_cast<UINT32>(gx) * src_width) / static_cast<UINT32>(grid_w);
      const float y_val =
          SamplePixelLuminanceFromRow(row_ptr, abs_pitch, subtype, sx);
      const size_t idx =
          static_cast<size_t>(gy) * static_cast<size_t>(grid_w) +
          static_cast<size_t>(gx);
      (*out_grid)[idx] = y_val;
      lum_sum += y_val;
    }
  }

  *out_lum_sum = lum_sum;
  return true;
}

// Samples a 1D / contiguous buffer while resolving stripped row padding from
// ConvertToContiguousBuffer vs. padded MF_MT_DEFAULT_STRIDE.
bool SampleContiguousBufferToGrayscaleGrid(
    const uint8_t* raw_data, size_t buffer_len, const GUID& subtype,
    UINT32 src_width, UINT32 src_height, int32_t reported_stride,
    bool is_contiguous_copy, int32_t grid_w, int32_t grid_h,
    std::vector<float>* out_grid, float* out_lum_sum) {
  if (raw_data == nullptr || src_width == 0 || src_height == 0 ||
      grid_w <= 0 || grid_h <= 0) {
    return false;
  }

  const size_t min_stride =
      static_cast<size_t>(DefaultStrideForSubtype(subtype, src_width));
  const size_t min_luma_bytes = min_stride * static_cast<size_t>(src_height);
  if (buffer_len < min_luma_bytes) {
    return false;
  }

  const size_t abs_reported = static_cast<size_t>(
      reported_stride < 0
          ? -reported_stride
          : (reported_stride > 0 ? reported_stride
                                 : static_cast<int32_t>(min_stride)));
  const size_t contiguous_total =
      ContiguousFrameBytesForSubtype(subtype, src_width, src_height);

  size_t effective_stride = abs_reported;
  if (is_contiguous_copy || abs_reported < min_stride) {
    effective_stride = min_stride;
  } else if (abs_reported > min_stride &&
             (buffer_len < abs_reported * static_cast<size_t>(src_height) ||
              buffer_len == contiguous_total)) {
    effective_stride = min_stride;
  }

  const bool bottom_up =
      (reported_stride < 0) &&
      (subtype == MFVideoFormat_RGB32 || subtype == MFVideoFormat_ARGB32 ||
       subtype == MFVideoFormat_RGB24);

  const size_t count =
      static_cast<size_t>(grid_w) * static_cast<size_t>(grid_h);
  out_grid->assign(count, 0.0f);
  float lum_sum = 0.0f;

  for (int32_t gy = 0; gy < grid_h; ++gy) {
    UINT32 sy =
        (static_cast<UINT32>(gy) * src_height) / static_cast<UINT32>(grid_h);
    if (bottom_up) {
      sy = (src_height - 1u) - sy;
    }
    const size_t row_offset = static_cast<size_t>(sy) * effective_stride;
    if (row_offset >= buffer_len) {
      return false;
    }
    const uint8_t* row_ptr = raw_data + row_offset;
    const size_t remaining_bytes = buffer_len - row_offset;

    for (int32_t gx = 0; gx < grid_w; ++gx) {
      const UINT32 sx =
          (static_cast<UINT32>(gx) * src_width) / static_cast<UINT32>(grid_w);
      const float y_val =
          SamplePixelLuminanceFromRow(row_ptr, remaining_bytes, subtype, sx);
      const size_t idx =
          static_cast<size_t>(gy) * static_cast<size_t>(grid_w) +
          static_cast<size_t>(gx);
      (*out_grid)[idx] = y_val;
      lum_sum += y_val;
    }
  }

  *out_lum_sum = lum_sum;
  return true;
}

bool SampleMediaSampleToGrayscaleGrid(IMFSample* sample, const GUID& subtype,
                                      UINT32 src_width, UINT32 src_height,
                                      int32_t reported_stride, int32_t grid_w,
                                      int32_t grid_h,
                                      std::vector<float>* out_grid,
                                      float* out_lum_sum) {
  if (sample == nullptr) {
    return false;
  }

  // 1. Prefer locking native 2D surface directly via IMF2DBuffer::Lock2D so
  //    GPU surface pitch is honored without copying or row-skewing.
  DWORD buffer_count = 0;
  if (SUCCEEDED(sample->GetBufferCount(&buffer_count)) && buffer_count == 1) {
    ComPtr<IMFMediaBuffer> first_buffer;
    if (SUCCEEDED(sample->GetBufferByIndex(0, first_buffer.GetAddressOf())) &&
        first_buffer != nullptr) {
      ComPtr<IMF2DBuffer> buffer_2d;
      BYTE* scanline0 = nullptr;
      LONG pitch = 0;
      if (SUCCEEDED(first_buffer.As(&buffer_2d)) && buffer_2d != nullptr &&
          SUCCEEDED(buffer_2d->Lock2D(&scanline0, &pitch))) {
        const bool ok = Sample2DSurfaceToGrayscaleGrid(
            scanline0, pitch, subtype, src_width, src_height, grid_w, grid_h,
            out_grid, out_lum_sum);
        buffer_2d->Unlock2D();
        if (ok) {
          return true;
        }
      }
    }
  }

  // 2. Fallback: convert to a contiguous 1D buffer (which strips 2D row
  //    padding via ContiguousCopyTo) and sample using the unpadded row stride.
  bool had_2d_buffer = false;
  if (buffer_count == 1) {
    ComPtr<IMFMediaBuffer> first_buffer;
    ComPtr<IMF2DBuffer> check_2d;
    if (SUCCEEDED(sample->GetBufferByIndex(0, first_buffer.GetAddressOf())) &&
        first_buffer != nullptr && SUCCEEDED(first_buffer.As(&check_2d)) &&
        check_2d != nullptr) {
      had_2d_buffer = true;
    }
  }

  ComPtr<IMFMediaBuffer> contiguous;
  if (FAILED(sample->ConvertToContiguousBuffer(contiguous.GetAddressOf())) ||
      contiguous == nullptr) {
    return false;
  }

  BYTE* raw_ptr = nullptr;
  DWORD max_len = 0;
  DWORD cur_len = 0;
  if (FAILED(contiguous->Lock(&raw_ptr, &max_len, &cur_len)) ||
      raw_ptr == nullptr || cur_len == 0) {
    return false;
  }

  const bool sampled = SampleContiguousBufferToGrayscaleGrid(
      raw_ptr, static_cast<size_t>(cur_len), subtype, src_width, src_height,
      reported_stride, had_2d_buffer || (buffer_count > 1), grid_w, grid_h,
      out_grid, out_lum_sum);
  contiguous->Unlock();
  return sampled;
}

struct FlowCoherenceStats {
  int32_t coherent_count = 0;
  double rigid_coherence = 0.0;
  double mean_dx = 0.0;
  double mean_dy = 0.0;
  bool is_looming = false;
};

FlowCoherenceStats EvaluateFlowCoherence(const std::vector<double>& dx_list,
                                         const std::vector<double>& dy_list,
                                         const std::vector<int32_t>& bx_list,
                                         const std::vector<int32_t>& by_list) {
  FlowCoherenceStats stats;
  const size_t n = dx_list.size();
  if (n == 0) {
    return stats;
  }
  double sum_dx = 0.0;
  double sum_dy = 0.0;
  double sum_mag = 0.0;
  double cx = 0.0;
  double cy = 0.0;
  for (size_t k = 0; k < n; ++k) {
    sum_dx += dx_list[k];
    sum_dy += dy_list[k];
    sum_mag += std::sqrt((dx_list[k] * dx_list[k]) + (dy_list[k] * dy_list[k]));
    cx += static_cast<double>(bx_list[k]);
    cy += static_cast<double>(by_list[k]);
  }
  stats.mean_dx = sum_dx / static_cast<double>(n);
  stats.mean_dy = sum_dy / static_cast<double>(n);
  const double mean_mag = sum_mag / static_cast<double>(n);
  cx /= static_cast<double>(n);
  cy /= static_cast<double>(n);

  const double net_mag =
      std::sqrt((stats.mean_dx * stats.mean_dx) + (stats.mean_dy * stats.mean_dy));
  const double pan_coherence =
      mean_mag > 1e-6 ? std::clamp(net_mag / mean_mag, 0.0, 1.0) : 0.0;

  int32_t pan_aligned = 0;
  int32_t roll_pos = 0;
  int32_t roll_neg = 0;
  double tangential_cos_sum = 0.0;
  double radial_cos_sum = 0.0;
  int32_t radial_samples = 0;

  for (size_t k = 0; k < n; ++k) {
    const double ux = dx_list[k];
    const double uy = dy_list[k];
    const double mag = std::sqrt((ux * ux) + (uy * uy));
    if (mag <= 1e-6) {
      continue;
    }
    if (net_mag > 1e-6) {
      const double cos_pan =
          ((ux * stats.mean_dx) + (uy * stats.mean_dy)) / (mag * net_mag);
      if (cos_pan >= 0.45) {
        pan_aligned += 1;
      }
    }
    const double ox = static_cast<double>(bx_list[k]) - 1.5;
    const double oy = static_cast<double>(by_list[k]) - 1.5;
    const double o_rad = std::sqrt((ox * ox) + (oy * oy));
    const double cross = (ox * uy) - (oy * ux);
    if (cross > 0.25) {
      roll_pos += 1;
    } else if (cross < -0.25) {
      roll_neg += 1;
    }
    if (o_rad >= 0.45) {
      tangential_cos_sum += ((ux * (-oy / o_rad)) + (uy * (ox / o_rad))) / mag;
    }
    const double rx = static_cast<double>(bx_list[k]) - cx;
    const double ry = static_cast<double>(by_list[k]) - cy;
    const double r_rad = std::sqrt((rx * rx) + (ry * ry));
    if (r_rad >= 0.45) {
      radial_cos_sum += ((ux * (rx / r_rad)) + (uy * (ry / r_rad))) / mag;
      radial_samples += 1;
    }
  }

  const double roll_coherence =
      std::clamp(std::abs(tangential_cos_sum) / static_cast<double>(n), 0.0, 1.0);
  stats.rigid_coherence = std::max(pan_coherence, roll_coherence);
  const double radial_divergence =
      radial_samples >= 3
          ? std::clamp(radial_cos_sum / static_cast<double>(radial_samples), -1.0,
                       1.0)
          : 0.0;
  stats.coherent_count = std::max(pan_aligned, std::max(roll_pos, roll_neg));
  stats.is_looming =
      n >= 3 && std::abs(radial_divergence) >= 0.44 && stats.rigid_coherence < 0.64;
  return stats;
}

std::optional<bool> QueryWindowsAcPowerOnline() {
  SYSTEM_POWER_STATUS pwr{};
  if (::GetSystemPowerStatus(&pwr) && pwr.ACLineStatus != 255) {
    return pwr.ACLineStatus == 1;
  }
  return std::nullopt;
}

bool EstimateLucasKanadeFlow(const std::vector<float>& previous,
                             const std::vector<float>& current, int32_t grid_w,
                             int32_t grid_h, double step_mean_shift,
                             int32_t x0, int32_t y0, int32_t w, int32_t h,
                             double* out_u, double* out_v,
                             double min_magnitude = 0.32) {
  const int32_t start_x = std::max<int32_t>(1, x0);
  const int32_t end_x = std::min<int32_t>(grid_w - 1, x0 + w);
  const int32_t start_y = std::max<int32_t>(1, y0);
  const int32_t end_y = std::min<int32_t>(grid_h - 1, y0 + h);
  if (end_x <= start_x + 2 || end_y <= start_y + 2) {
    return false;
  }

  double sxx = 0.0;
  double syy = 0.0;
  double sxy = 0.0;
  double bx = 0.0;
  double by = 0.0;
  int32_t count = 0;

  for (int32_t y = start_y; y < end_y; ++y) {
    const size_t row = static_cast<size_t>(y) * static_cast<size_t>(grid_w);
    const size_t row_up =
        static_cast<size_t>(y - 1) * static_cast<size_t>(grid_w);
    const size_t row_down =
        static_cast<size_t>(y + 1) * static_cast<size_t>(grid_w);
    for (int32_t x = start_x; x < end_x; ++x) {
      const size_t sx = static_cast<size_t>(x);
      const double ix = 0.25 * static_cast<double>(
                                   (previous[row + sx + 1u] -
                                    previous[row + sx - 1u]) +
                                   (current[row + sx + 1u] -
                                    current[row + sx - 1u]));
      const double iy = 0.25 * static_cast<double>(
                                   (previous[row_down + sx] -
                                    previous[row_up + sx]) +
                                   (current[row_down + sx] -
                                    current[row_up + sx]));
      const double it = static_cast<double>(current[row + sx] -
                                            previous[row + sx]) -
                        step_mean_shift;

      sxx += ix * ix;
      syy += iy * iy;
      sxy += ix * iy;
      bx -= ix * it;
      by -= iy * it;
      count += 1;
    }
  }

  if (count == 0) {
    return false;
  }
  const double trace = sxx + syy;
  const double det = (sxx * syy) - (sxy * sxy);
  const double disc = std::max(0.0, (trace * trace) - (4.0 * det));
  const double min_eigen = 0.5 * (trace - std::sqrt(disc));
  if (det <= 1e-3 || min_eigen < static_cast<double>(count) * 6.0) {
    return false;
  }

  const double u = ((syy * bx) - (sxy * by)) / det;
  const double v = ((-sxy * bx) + (sxx * by)) / det;
  const double mag = std::sqrt((u * u) + (v * v));
  if (mag < min_magnitude || mag > 3.8) {
    return false;
  }
  *out_u = u;
  *out_v = v;
  return true;
}

bool EstimateBlockTranslation(const std::vector<float>& previous,
                              const std::vector<float>& current, int32_t grid_w,
                              int32_t grid_h, double step_mean_shift,
                              int32_t x0, int32_t y0, int32_t w, int32_t h,
                              double* out_u, double* out_v) {
  constexpr int32_t kMaxShift = 3;
  const int32_t start_x = std::max<int32_t>(kMaxShift, x0 + 1);
  const int32_t end_x = std::min<int32_t>(grid_w - kMaxShift, x0 + w - 1);
  const int32_t start_y = std::max<int32_t>(kMaxShift, y0 + 1);
  const int32_t end_y = std::min<int32_t>(grid_h - kMaxShift, y0 + h - 1);
  if (end_x <= start_x + 2 || end_y <= start_y + 2) {
    return false;
  }

  auto sad_for_shift = [&](int32_t dx, int32_t dy) -> double {
    double sad = 0.0;
    for (int32_t y = start_y; y < end_y; ++y) {
      const size_t prev_row =
          static_cast<size_t>(y) * static_cast<size_t>(grid_w);
      const size_t curr_row =
          static_cast<size_t>(y + dy) * static_cast<size_t>(grid_w);
      for (int32_t x = start_x; x < end_x; ++x) {
        const double prev_val =
            static_cast<double>(previous[prev_row + static_cast<size_t>(x)]);
        const double curr_val =
            static_cast<double>(
                current[curr_row + static_cast<size_t>(x + dx)]) -
            step_mean_shift;
        sad += std::abs(curr_val - prev_val);
      }
    }
    return sad;
  };

  const double sad_zero = sad_for_shift(0, 0);
  const int32_t sample_pixels = (end_x - start_x) * (end_y - start_y);
  if (sad_zero / static_cast<double>(sample_pixels) < 2.2) {
    return false;
  }

  double best_sad = sad_zero;
  int32_t best_dx = 0;
  int32_t best_dy = 0;
  for (int32_t dy = -kMaxShift; dy <= kMaxShift; ++dy) {
    for (int32_t dx = -kMaxShift; dx <= kMaxShift; ++dx) {
      if (dx == 0 && dy == 0) {
        continue;
      }
      const double sad = sad_for_shift(dx, dy);
      if (sad < best_sad) {
        best_sad = sad;
        best_dx = dx;
        best_dy = dy;
      }
    }
  }

  if ((best_dx != 0 || best_dy != 0) && best_sad < sad_zero * 0.84) {
    *out_u = static_cast<double>(best_dx);
    *out_v = static_cast<double>(best_dy);
    return true;
  }
  return false;
}

bool IsWindowsCameraBusyHresult(HRESULT hr) {
  constexpr HRESULT kMfHwFailedStartStreaming =
      static_cast<HRESULT>(0xC00D3704L);
  constexpr HRESULT kMfDeviceInvalidated = static_cast<HRESULT>(0xC00D3EA2L);
  return hr == kMfHwFailedStartStreaming || hr == kMfDeviceInvalidated ||
         hr == HRESULT_FROM_WIN32(ERROR_SHARING_VIOLATION) ||
         hr == HRESULT_FROM_WIN32(ERROR_BUSY) ||
         hr == HRESULT_FROM_WIN32(ERROR_LOCK_VIOLATION);
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

  void OnSystemSuspend(bool protection_armed) {
    std::string session_id;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      session_id = active_session_id_;
      if (!session_id.empty()) {
        paused_session_id_ = session_id;
      }
    }
    if (!session_id.empty()) {
      StopCapture();
      if (!protection_armed) {
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
  }

  void OnSystemResume() {
    std::string session_id;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      session_id =
          !active_session_id_.empty() ? active_session_id_ : paused_session_id_;
      paused_session_id_.clear();
    }
    if (!session_id.empty()) {
      EmitEvent(flutter::EncodableMap{
          {flutter::EncodableValue("sessionId"),
           flutter::EncodableValue(session_id)},
          {flutter::EncodableValue("eventType"),
           flutter::EncodableValue("lifecycleResumed")},
          {flutter::EncodableValue("summary"),
           flutter::EncodableValue(
               "Windows system woke from sleep; webcam monitoring ready to resume.")},
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

    if (QueryWindowsCameraPermissionStatus() != "granted") {
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

    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      paused_session_id_.clear();
      active_session_id_ = session_id;
    }
    motion_threshold_.store(threshold);
    running_.store(true);

    auto pending_result = std::make_shared<
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>>(
        std::move(result));
    auto pending_mutex = std::make_shared<std::mutex>();
    auto dispatcher = dispatcher_;

    auto complete_start = [pending_result, pending_mutex, dispatcher](
                              bool started, const std::string& message,
                              const std::string& error_code) {
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> owned;
      {
        std::lock_guard<std::mutex> lock(*pending_mutex);
        if (!(*pending_result)) {
          return;
        }
        owned = std::move(*pending_result);
      }
      flutter::EncodableMap payload{
          {flutter::EncodableValue("started"),
           flutter::EncodableValue(started)},
          {flutter::EncodableValue("message"),
           flutter::EncodableValue(message)},
      };
      if (!error_code.empty()) {
        payload.emplace(flutter::EncodableValue("errorCode"),
                        flutter::EncodableValue(error_code));
      }
      auto shared_owned = std::make_shared<
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>>(
          std::move(owned));
      dispatcher->Post([shared_owned, payload = std::move(payload)]() {
        if (*shared_owned) {
          (*shared_owned)->Success(flutter::EncodableValue(payload));
        }
      });
    };

    worker_thread_ = std::thread([this, session_id, calibration_ms,
                                  persistence_frames, grid_w, grid_h,
                                  complete_start]() mutable {
      RunCameraLoop(session_id, calibration_ms, persistence_frames, grid_w,
                    grid_h, std::move(complete_start));
    });
  }

  void RunCameraLoop(
      const std::string& session_id, int32_t calibration_ms,
      int32_t persistence_frames, int32_t grid_w, int32_t grid_h,
      std::function<void(bool, const std::string&, const std::string&)>
          complete_start) {
    ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    auto clear_session_if_current = [this, &session_id]() {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (active_session_id_ == session_id) {
        active_session_id_.clear();
      }
    };

    CameraDeviceProbe probe = ProbeWindowsCamera();
    if (probe.permission_status != "granted") {
      clear_session_if_current();
      complete_start(false,
                     "Windows camera access is disabled in Privacy Settings.",
                     "PERMISSION_NOT_GRANTED");
      ::CoUninitialize();
      return;
    }

    if (!probe.has_hardware || probe.activate == nullptr) {
      clear_session_if_current();
      complete_start(false, "No Windows camera hardware found.",
                     "NO_CAMERA_HARDWARE");
      ::CoUninitialize();
      return;
    }

    ComPtr<IMFMediaSource> media_source;
    HRESULT hr = probe.activate->ActivateObject(
        IID_PPV_ARGS(media_source.GetAddressOf()));
    if (FAILED(hr) || media_source == nullptr) {
      clear_session_if_current();
      const bool access_denied =
          (hr == E_ACCESSDENIED ||
           hr == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED));
      const bool busy = IsWindowsCameraBusyHresult(hr);
      complete_start(
          false,
          access_denied
              ? "Windows blocked camera access. Check Settings > Privacy & security > Camera."
              : (busy ? (probe.device_name +
                         " is currently in use by another application.")
                      : "Failed to activate Windows camera media source (camera may be in use)."),
          access_denied ? "PERMISSION_DENIED"
                        : (busy ? "CAMERA_BUSY" : "SOURCE_ACTIVATE_FAILED"));
      ::CoUninitialize();
      return;
    }

    ComPtr<IMFAttributes> reader_attrs;
    ::MFCreateAttributes(reader_attrs.GetAddressOf(), 2);
    if (reader_attrs != nullptr) {
      reader_attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
      reader_attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    }

    ComPtr<IMFSourceReader> reader;
    hr = ::MFCreateSourceReaderFromMediaSource(
        media_source.Get(), reader_attrs.Get(), reader.GetAddressOf());
    if (FAILED(hr) || reader == nullptr) {
      media_source->Shutdown();
      clear_session_if_current();
      const bool busy = IsWindowsCameraBusyHresult(hr);
      complete_start(
          false,
          busy ? (probe.device_name +
                  " is currently in use by another application.")
               : "Failed to create Media Foundation source reader for camera.",
          busy ? "CAMERA_BUSY" : "READER_CREATE_FAILED");
      ::CoUninitialize();
      return;
    }

    GUID subtype = GUID_NULL;
    UINT32 src_width = 0;
    UINT32 src_height = 0;
    int32_t stride = 0;
    if (!ConfigureSourceReaderVideoFormat(reader.Get(), &subtype, &src_width,
                                          &src_height, &stride)) {
      reader.Reset();
      media_source->Shutdown();
      clear_session_if_current();
      complete_start(
          false,
          "Could not negotiate a compatible video format with the camera.",
          "UNSUPPORTED_VIDEO_FORMAT");
      ::CoUninitialize();
      return;
    }

    const std::string device_name = probe.device_name;
    const int64_t open_start_ms = CurrentTimeMillis();
    int64_t session_start_ms = open_start_ms;
    int64_t last_frame_processed_ms = 0;
    bool has_delivered_first_frame = false;
    bool is_calibration_done = false;
    std::vector<float> reference_grid;
    std::vector<float> previous_grid;
    std::deque<std::vector<float>> recent_grids;
    int32_t settled_block_streak[16] = {0};
    std::vector<float> current_grid;
    float previous_mean_255 = 0.0f;
    double prev_mean_flow_dx = 0.0;
    double prev_mean_flow_dy = 0.0;
    bool has_prev_mean_flow = false;
    std::optional<bool> was_on_ac_power = QueryWindowsAcPowerOnline();
    int64_t last_ac_unplug_ms = 0;
    int32_t consecutive_above_threshold = 0;
    int32_t consecutive_poor_input = 0;
    bool is_input_degraded = false;
    int32_t processed_frame_count = 0;

    while (running_.load()) {
      DWORD stream_index = 0;
      DWORD stream_flags = 0;
      LONGLONG sample_timestamp = 0;
      ComPtr<IMFSample> sample;

      hr = reader->ReadSample(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0,
          &stream_index, &stream_flags, &sample_timestamp,
          sample.GetAddressOf());

      if (!running_.load()) {
        if (!has_delivered_first_frame) {
          complete_start(false, "Camera startup cancelled before first frame.",
                         "STARTUP_CANCELLED");
        }
        break;
      }

      if (FAILED(hr) || (stream_flags & MF_SOURCE_READERF_ERROR)) {
        const bool access_denied =
            (hr == E_ACCESSDENIED ||
             hr == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED));
        const bool busy = IsWindowsCameraBusyHresult(hr);
        if (!has_delivered_first_frame) {
          clear_session_if_current();
          complete_start(
              false,
              access_denied
                  ? "Windows blocked camera access. Check Settings > Privacy & security > Camera."
                  : (busy ? (device_name +
                             " is currently in use by another application.")
                          : "Windows webcam failed to start streaming."),
              access_denied ? "PERMISSION_DENIED"
                            : (busy ? "CAMERA_BUSY" : "MF_CAPTURE_ERROR"));
        } else {
          EmitEvent(flutter::EncodableMap{
              {flutter::EncodableValue("sessionId"),
               flutter::EncodableValue(session_id)},
              {flutter::EncodableValue("eventType"),
               flutter::EncodableValue("detectorFailed")},
              {flutter::EncodableValue("summary"),
               flutter::EncodableValue(
                   busy ? (device_name +
                           " was claimed by another application.")
                        : "Windows webcam stream error or device disconnected.")},
              {flutter::EncodableValue("errorCode"),
               flutter::EncodableValue(busy ? "CAMERA_BUSY"
                                            : "MF_CAPTURE_ERROR")},
              {flutter::EncodableValue("timestampMs"),
               flutter::EncodableValue(CurrentTimeMillis())},
          });
        }
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

      const int64_t now_ms = CurrentTimeMillis();
      if (sample == nullptr) {
        if (!has_delivered_first_frame && (now_ms - open_start_ms) >= 4000) {
          clear_session_if_current();
          complete_start(
              false,
              "Camera opened on " + device_name +
                  ", but no video frames arrived within 4 seconds.",
              "FRAME_TIMEOUT");
          break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(15));
        continue;
      }

      // Throttle to ~8 frames per second off the UI thread (never throttle the
      // very first frame).
      if (has_delivered_first_frame &&
          (now_ms - last_frame_processed_ms) < 120) {
        continue;
      }

      float lum_sum = 0.0f;
      const bool sampled = SampleMediaSampleToGrayscaleGrid(
          sample.Get(), subtype, src_width, src_height, stride, grid_w, grid_h,
          &current_grid, &lum_sum);

      if (!sampled || current_grid.empty()) {
        if (!has_delivered_first_frame && (now_ms - open_start_ms) >= 4000) {
          clear_session_if_current();
          complete_start(
              false,
              "Camera frames from " + device_name +
                  " could not be decoded into a valid video buffer.",
              "FRAME_TIMEOUT");
          break;
        }
        continue;
      }

      last_frame_processed_ms = now_ms;
      const double active_threshold = motion_threshold_.load();

      // Report monitoring started ONLY once frames are actually arriving.
      if (!has_delivered_first_frame) {
        has_delivered_first_frame = true;
        session_start_ms = now_ms;
        EmitEvent(flutter::EncodableMap{
            {flutter::EncodableValue("sessionId"),
             flutter::EncodableValue(session_id)},
            {flutter::EncodableValue("eventType"),
             flutter::EncodableValue("calibrationStarted")},
            {flutter::EncodableValue("summary"),
             flutter::EncodableValue("Calibrating baseline scene on " +
                                     device_name + "...")},
            {flutter::EncodableValue("threshold"),
             flutter::EncodableValue(active_threshold)},
            {flutter::EncodableValue("timestampMs"),
             flutter::EncodableValue(now_ms)},
        });
        complete_start(true, "Monitoring active on " + device_name + ".", "");
      }

      const size_t count = current_grid.size();
      const float curr_mean = lum_sum / static_cast<float>(count);
      const double normalized_luminance =
          static_cast<double>(curr_mean / 255.0f);

      float dev_sum = 0.0f;
      for (float val : current_grid) {
        dev_sum += std::abs(val - curr_mean);
      }
      const float curr_mad = dev_sum / static_cast<float>(count);
      const double normalized_deviation =
          static_cast<double>(curr_mad / 255.0f);

      processed_frame_count += 1;

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

      if (reference_grid.size() != count || previous_grid.size() != count) {
        reference_grid = current_grid;
        previous_grid = current_grid;
        previous_mean_255 = curr_mean;
        continue;
      }

      const int64_t elapsed_ms = now_ms - session_start_ms;
      if (!is_calibration_done) {
        for (size_t i = 0; i < count; ++i) {
          reference_grid[i] =
              (0.65f * reference_grid[i]) + (0.35f * current_grid[i]);
          previous_grid[i] = current_grid[i];
        }
        previous_mean_255 = curr_mean;
        if (elapsed_ms >= calibration_ms && processed_frame_count >= 4) {
          is_calibration_done = true;
          recent_grids.clear();
          recent_grids.push_back(reference_grid);
          EmitEvent(flutter::EncodableMap{
              {flutter::EncodableValue("sessionId"),
               flutter::EncodableValue(session_id)},
              {flutter::EncodableValue("eventType"),
               flutter::EncodableValue("calibrationCompleted")},
              {flutter::EncodableValue("summary"),
               flutter::EncodableValue(
                   "Scene baseline calibrated. Ego-motion optical flow filtering enabled.")},
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

      if (const auto now_ac = QueryWindowsAcPowerOnline(); now_ac.has_value()) {
        if (was_on_ac_power.has_value() && *was_on_ac_power && !(*now_ac)) {
          last_ac_unplug_ms = now_ms;
        }
        was_on_ac_power = now_ac;
      }
      const bool ac_power_unplugged_recently =
          last_ac_unplug_ms > 0 && (now_ms - last_ac_unplug_ms) <= 8000;

      const std::vector<float>& window_grid =
          !recent_grids.empty() ? recent_grids.front() : previous_grid;
      const bool has_window_span = recent_grids.size() >= 3;

      // Per-block zero-mean & affine illumination normalization + 4x4 Lucas-Kanade ego-motion
      constexpr int32_t kBlocksX = 4;
      constexpr int32_t kBlocksY = 4;
      constexpr int32_t kTotalBlocks = kBlocksX * kBlocksY;
      double block_curr_sum[kTotalBlocks] = {0.0};
      double block_ref_sum[kTotalBlocks] = {0.0};
      double block_prev_sum[kTotalBlocks] = {0.0};
      double block_win_sum[kTotalBlocks] = {0.0};
      int32_t block_pixel_count[kTotalBlocks] = {0};

      for (int32_t gy = 0; gy < grid_h; ++gy) {
        const int32_t by =
            std::min(kBlocksY - 1, (gy * kBlocksY) / std::max(1, grid_h));
        for (int32_t gx = 0; gx < grid_w; ++gx) {
          const int32_t bx =
              std::min(kBlocksX - 1, (gx * kBlocksX) / std::max(1, grid_w));
          const int32_t b_idx = by * kBlocksX + bx;
          const size_t i =
              static_cast<size_t>(gy) * static_cast<size_t>(grid_w) +
              static_cast<size_t>(gx);
          block_curr_sum[b_idx] += static_cast<double>(current_grid[i]);
          block_ref_sum[b_idx] += static_cast<double>(reference_grid[i]);
          block_prev_sum[b_idx] += static_cast<double>(previous_grid[i]);
          block_win_sum[b_idx] += static_cast<double>(window_grid[i]);
          block_pixel_count[b_idx] += 1;
        }
      }

      double block_curr_mean[kTotalBlocks] = {0.0};
      double block_ref_mean[kTotalBlocks] = {0.0};
      double block_prev_mean[kTotalBlocks] = {0.0};
      double block_win_mean[kTotalBlocks] = {0.0};
      for (int32_t b = 0; b < kTotalBlocks; ++b) {
        if (block_pixel_count[b] > 0) {
          const double n = static_cast<double>(block_pixel_count[b]);
          block_curr_mean[b] = block_curr_sum[b] / n;
          block_ref_mean[b] = block_ref_sum[b] / n;
          block_prev_mean[b] = block_prev_sum[b] / n;
          block_win_mean[b] = block_win_sum[b] / n;
        }
      }

      double block_curr_dev_sum[kTotalBlocks] = {0.0};
      double block_ref_dev_sum[kTotalBlocks] = {0.0};
      double block_prev_dev_sum[kTotalBlocks] = {0.0};
      for (int32_t gy = 0; gy < grid_h; ++gy) {
        const int32_t by =
            std::min(kBlocksY - 1, (gy * kBlocksY) / std::max(1, grid_h));
        for (int32_t gx = 0; gx < grid_w; ++gx) {
          const int32_t bx =
              std::min(kBlocksX - 1, (gx * kBlocksX) / std::max(1, grid_w));
          const int32_t b_idx = by * kBlocksX + bx;
          const size_t i =
              static_cast<size_t>(gy) * static_cast<size_t>(grid_w) +
              static_cast<size_t>(gx);
          block_curr_dev_sum[b_idx] += std::abs(
              static_cast<double>(current_grid[i]) - block_curr_mean[b_idx]);
          block_ref_dev_sum[b_idx] += std::abs(
              static_cast<double>(reference_grid[i]) - block_ref_mean[b_idx]);
          block_prev_dev_sum[b_idx] += std::abs(
              static_cast<double>(previous_grid[i]) - block_prev_mean[b_idx]);
        }
      }

      double block_gain_to_ref[kTotalBlocks];
      double block_gain_to_prev[kTotalBlocks];
      for (int32_t b = 0; b < kTotalBlocks; ++b) {
        block_gain_to_ref[b] = 1.0;
        block_gain_to_prev[b] = 1.0;
        if (block_pixel_count[b] > 0) {
          const double n = static_cast<double>(block_pixel_count[b]);
          const double c_mad = block_curr_dev_sum[b] / n;
          const double r_mad = block_ref_dev_sum[b] / n;
          const double p_mad = block_prev_dev_sum[b] / n;
          if (c_mad > 2.5 && r_mad > 2.5) {
            block_gain_to_ref[b] = std::clamp(r_mad / c_mad, 0.66, 1.50);
          }
          if (c_mad > 2.5 && p_mad > 2.5) {
            block_gain_to_prev[b] = std::clamp(p_mad / c_mad, 0.74, 1.35);
          }
        }
      }

      double block_ref_diff_sum[kTotalBlocks] = {0.0};
      double block_step_diff_sum[kTotalBlocks] = {0.0};
      double block_win_diff_sum[kTotalBlocks] = {0.0};
      double block_ref_grad_sum[kTotalBlocks] = {0.0};
      double block_curr_grad_sum[kTotalBlocks] = {0.0};
      int32_t block_grad_count[kTotalBlocks] = {0};

      double norm_ref_diff_sum = 0.0;
      double norm_step_diff_sum = 0.0;
      for (int32_t gy = 0; gy < grid_h; ++gy) {
        const int32_t by =
            std::min(kBlocksY - 1, (gy * kBlocksY) / std::max(1, grid_h));
        for (int32_t gx = 0; gx < grid_w; ++gx) {
          const int32_t bx =
              std::min(kBlocksX - 1, (gx * kBlocksX) / std::max(1, grid_w));
          const int32_t b_idx = by * kBlocksX + bx;
          const size_t i =
              static_cast<size_t>(gy) * static_cast<size_t>(grid_w) +
              static_cast<size_t>(gx);

          const double curr_val = static_cast<double>(current_grid[i]);
          const double ref_val = static_cast<double>(reference_grid[i]);
          const double prev_val = static_cast<double>(previous_grid[i]);
          const double win_val = static_cast<double>(window_grid[i]);

          const double norm_curr_to_ref =
              (curr_val - block_curr_mean[b_idx]) * block_gain_to_ref[b_idx];
          const double ref_centered = ref_val - block_ref_mean[b_idx];
          const double ref_delta = std::abs(norm_curr_to_ref - ref_centered);

          const double norm_curr_to_prev =
              (curr_val - block_curr_mean[b_idx]) * block_gain_to_prev[b_idx];
          const double prev_centered = prev_val - block_prev_mean[b_idx];
          const double step_delta = std::abs(norm_curr_to_prev - prev_centered);

          const double win_shift =
              block_curr_mean[b_idx] - block_win_mean[b_idx];
          const double win_delta = std::abs((curr_val - win_val) - win_shift);

          norm_ref_diff_sum += ref_delta;
          norm_step_diff_sum += step_delta;
          block_ref_diff_sum[b_idx] += ref_delta;
          block_step_diff_sum[b_idx] += step_delta;
          block_win_diff_sum[b_idx] += win_delta;

          if (gx + 1 < grid_w && gy + 1 < grid_h) {
            const double gx_diff = std::abs(
                ref_val - static_cast<double>(reference_grid[i + 1u]));
            const double gy_diff = std::abs(
                ref_val - static_cast<double>(
                              reference_grid[i + static_cast<size_t>(grid_w)]));
            block_ref_grad_sum[b_idx] += 0.5 * (gx_diff + gy_diff);

            const double cgx_diff = std::abs(
                curr_val - static_cast<double>(current_grid[i + 1u]));
            const double cgy_diff = std::abs(
                curr_val - static_cast<double>(
                               current_grid[i + static_cast<size_t>(grid_w)]));
            block_curr_grad_sum[b_idx] += 0.5 * (cgx_diff + cgy_diff);
            block_grad_count[b_idx] += 1;
          }
        }
      }

      const double static_block_threshold =
          std::max(0.020, active_threshold * 0.36);
      const double active_block_threshold =
          std::max(0.024, active_threshold * 0.48);
      const int32_t block_w = grid_w / kBlocksX;
      const int32_t block_h = grid_h / kBlocksY;

      int32_t textured_ref_blocks = 0;
      int32_t anchored_textured_blocks = 0;
      int32_t textured_perimeter_blocks = 0;
      int32_t anchored_perimeter_blocks = 0;
      int32_t active_moving_blocks = 0;
      double textured_ref_score_sum = 0.0;
      std::vector<double> dx_list;
      std::vector<double> dy_list;
      std::vector<int32_t> bx_list;
      std::vector<int32_t> by_list;
      int32_t quadrant_activity[4] = {0, 0, 0, 0};

      std::vector<double> win_dx_list;
      std::vector<double> win_dy_list;
      std::vector<int32_t> win_bx_list;
      std::vector<int32_t> win_by_list;
      int32_t win_quadrant_activity[4] = {0, 0, 0, 0};

      for (int32_t by = 0; by < kBlocksY; ++by) {
        for (int32_t bx = 0; bx < kBlocksX; ++bx) {
          const int32_t b = by * kBlocksX + bx;
          const int32_t px_count = block_pixel_count[b];
          if (px_count <= 0) {
            continue;
          }
          const double ref_score =
              block_ref_diff_sum[b] / static_cast<double>(px_count * 255);
          const double step_score =
              block_step_diff_sum[b] / static_cast<double>(px_count * 255);
          const double win_score =
              block_win_diff_sum[b] / static_cast<double>(px_count * 255);
          const double mean_grad =
              block_grad_count[b] > 0
                  ? (block_ref_grad_sum[b] /
                     static_cast<double>(block_grad_count[b]))
                  : 0.0;
          const double curr_grad =
              block_grad_count[b] > 0
                  ? (block_curr_grad_sum[b] /
                     static_cast<double>(block_grad_count[b]))
                  : 0.0;
          const bool is_textured = mean_grad >= 3.2;
          const bool is_perimeter =
              bx == 0 || bx == (kBlocksX - 1) || by == 0 || by == (kBlocksY - 1);

          if (step_score < 0.010) {
            settled_block_streak[b] += 1;
          } else {
            settled_block_streak[b] = 0;
          }

          if (is_textured) {
            textured_ref_blocks += 1;
            textured_ref_score_sum += ref_score;
            if (is_perimeter) {
              textured_perimeter_blocks += 1;
            }
            if (ref_score < static_block_threshold && step_score < 0.016) {
              anchored_textured_blocks += 1;
              if (is_perimeter) {
                anchored_perimeter_blocks += 1;
              }
            }
          }

          const double block_step_shift =
              block_curr_mean[b] - block_prev_mean[b];
          bool block_translated = false;
          if (is_textured && curr_grad >= 2.4 && step_score >= 0.008 &&
              block_w >= 6 && block_h >= 6) {
            double flow_u = 0.0;
            double flow_v = 0.0;
            if (EstimateLucasKanadeFlow(previous_grid, current_grid, grid_w,
                                        grid_h, block_step_shift, bx * block_w,
                                        by * block_h, block_w, block_h, &flow_u,
                                        &flow_v, 0.32) ||
                EstimateBlockTranslation(previous_grid, current_grid, grid_w,
                                         grid_h, block_step_shift, bx * block_w,
                                         by * block_h, block_w, block_h,
                                         &flow_u, &flow_v)) {
              block_translated = true;
              dx_list.push_back(flow_u);
              dy_list.push_back(flow_v);
              bx_list.push_back(bx);
              by_list.push_back(by);
            }
          }

          if (has_window_span && is_textured && curr_grad >= 2.6 &&
              win_score >= 0.010 && block_w >= 6 && block_h >= 6) {
            const double win_shift = block_curr_mean[b] - block_win_mean[b];
            double wflow_u = 0.0;
            double wflow_v = 0.0;
            if (EstimateLucasKanadeFlow(window_grid, current_grid, grid_w,
                                        grid_h, win_shift, bx * block_w,
                                        by * block_h, block_w, block_h,
                                        &wflow_u, &wflow_v, 0.36) ||
                EstimateBlockTranslation(window_grid, current_grid, grid_w,
                                         grid_h, win_shift, bx * block_w,
                                         by * block_h, block_w, block_h,
                                         &wflow_u, &wflow_v)) {
              win_dx_list.push_back(wflow_u);
              win_dy_list.push_back(wflow_v);
              win_bx_list.push_back(bx);
              win_by_list.push_back(by);
              const int32_t qx = bx >= 2 ? 1 : 0;
              const int32_t qy = by >= 2 ? 1 : 0;
              win_quadrant_activity[qy * 2 + qx] += 1;
            }
          }

          if ((ref_score >= active_block_threshold && step_score >= 0.012) ||
              block_translated) {
            active_moving_blocks += 1;
            const int32_t qx = bx >= 2 ? 1 : 0;
            const int32_t qy = by >= 2 ? 1 : 0;
            quadrant_activity[qy * 2 + qx] += 1;
          }
        }
      }

      int32_t active_quadrants = 0;
      int32_t win_active_quadrants = 0;
      for (int32_t q = 0; q < 4; ++q) {
        if (quadrant_activity[q] >= 1) {
          active_quadrants += 1;
        }
        if (win_quadrant_activity[q] >= 1) {
          win_active_quadrants += 1;
        }
      }

      const FlowCoherenceStats step_flow =
          EvaluateFlowCoherence(dx_list, dy_list, bx_list, by_list);
      const FlowCoherenceStats win_flow = EvaluateFlowCoherence(
          win_dx_list, win_dy_list, win_bx_list, win_by_list);
      const int32_t coherent_translated_blocks = step_flow.coherent_count;
      const bool looming_rejected =
          step_flow.is_looming ||
          (coherent_translated_blocks < 5 && win_flow.is_looming);

      bool oscillation_rejected = false;
      const double curr_flow_mag = std::sqrt(
          (step_flow.mean_dx * step_flow.mean_dx) +
          (step_flow.mean_dy * step_flow.mean_dy));
      if (dx_list.size() >= 3 && curr_flow_mag >= 0.30) {
        if (has_prev_mean_flow) {
          const double prev_mag = std::sqrt(
              (prev_mean_flow_dx * prev_mean_flow_dx) +
              (prev_mean_flow_dy * prev_mean_flow_dy));
          if (prev_mag >= 0.30) {
            const double cos_turn =
                ((prev_mean_flow_dx * step_flow.mean_dx) +
                 (prev_mean_flow_dy * step_flow.mean_dy)) /
                (prev_mag * curr_flow_mag);
            if (cos_turn < -0.25) {
              oscillation_rejected = true;
            }
          }
        }
        prev_mean_flow_dx = step_flow.mean_dx;
        prev_mean_flow_dy = step_flow.mean_dy;
        has_prev_mean_flow = true;
      } else if (active_moving_blocks == 0) {
        has_prev_mean_flow = false;
      }

      const double full_scene_struct_score =
          norm_ref_diff_sum / static_cast<double>(count * 255u);
      const double mean_step_score =
          norm_step_diff_sum / static_cast<double>(count * 255u);
      const double textured_struct_score =
          textured_ref_blocks > 0
              ? (textured_ref_score_sum /
                 static_cast<double>(textured_ref_blocks))
              : full_scene_struct_score;
      const double struct_motion_score =
          (textured_ref_blocks >= 2 && textured_ref_blocks <= 6 &&
           anchored_textured_blocks == 0)
              ? std::max(full_scene_struct_score, textured_struct_score * 0.80)
              : full_scene_struct_score;

      const double mean_jump =
          static_cast<double>(std::abs(curr_mean - previous_mean_255));
      const bool is_lighting_transient =
          mean_jump >= 18.0 && coherent_translated_blocks <= 2;
      const int32_t min_anchors = std::max<int32_t>(
          3, static_cast<int32_t>(
                 std::ceil(static_cast<double>(textured_ref_blocks) * 0.22)));
      const int32_t min_perim_anchors = std::max<int32_t>(
          3, static_cast<int32_t>(std::ceil(
                 static_cast<double>(textured_perimeter_blocks) * 0.34)));
      const bool has_strong_static_anchors =
          (textured_ref_blocks >= 4 && anchored_textured_blocks >= min_anchors) ||
          (textured_perimeter_blocks >= 4 &&
           anchored_perimeter_blocks >= min_perim_anchors);

      const bool sparse_scene_coherent_ego_motion =
          textured_ref_blocks >= 2 && textured_ref_blocks <= 6 &&
          anchored_textured_blocks == 0 &&
          coherent_translated_blocks >=
              std::min<int32_t>(3, textured_ref_blocks) &&
          step_flow.rigid_coherence >= 0.58 && !looming_rejected;

      const bool sparse_scene_slow_drift =
          has_window_span && textured_ref_blocks >= 2 &&
          textured_ref_blocks <= 6 && anchored_textured_blocks == 0 &&
          win_flow.coherent_count >=
              std::min<int32_t>(3, textured_ref_blocks) &&
          win_flow.rigid_coherence >= 0.68 && !win_flow.is_looming;

      const bool full_scene_slow_drift =
          has_window_span && !has_strong_static_anchors &&
          !is_lighting_transient && !looming_rejected &&
          win_flow.coherent_count >= 5 && win_active_quadrants >= 3 &&
          win_flow.rigid_coherence >= 0.70;

      const bool is_scene_presently_still =
          coherent_translated_blocks == 0 && !full_scene_slow_drift &&
          !sparse_scene_slow_drift &&
          (active_moving_blocks <= 2 || mean_step_score < 0.009);

      double ego_weight = 0.32;
      if (is_lighting_transient || is_input_degraded) {
        ego_weight = 0.10;
      } else if (has_strong_static_anchors) {
        ego_weight = 0.14;
      } else if (looming_rejected) {
        ego_weight = 0.18;
      } else if (is_scene_presently_still) {
        ego_weight = 0.08;
      } else if (sparse_scene_coherent_ego_motion) {
        ego_weight = 1.20;
      } else if (coherent_translated_blocks >= 5 && active_quadrants >= 3 &&
                 step_flow.rigid_coherence >= 0.56) {
        ego_weight = 1.25;
      } else if (active_quadrants <= 2 && coherent_translated_blocks < 5) {
        ego_weight = 0.24;
      } else if (textured_ref_blocks > 0 && anchored_perimeter_blocks == 0 &&
                 anchored_textured_blocks == 0 && active_moving_blocks >= 12 &&
                 active_quadrants == 4 && normalized_deviation >= 0.028 &&
                 dx_list.size() >= 3 && step_flow.rigid_coherence >= 0.55) {
        ego_weight = 1.08;
      } else if (textured_ref_blocks == 0 && active_moving_blocks >= 13 &&
                 active_quadrants == 4 && mean_step_score >= 0.025 &&
                 normalized_deviation >= 0.015) {
        ego_weight = 0.95;
      }

      const double flow_contribution =
          (!has_strong_static_anchors && !looming_rejected &&
           coherent_translated_blocks >= 5 && active_quadrants >= 3 &&
           step_flow.rigid_coherence >= 0.56)
              ? (static_cast<double>(coherent_translated_blocks) /
                 static_cast<double>(kTotalBlocks)) *
                    0.11 * step_flow.rigid_coherence
              : (sparse_scene_coherent_ego_motion ? 0.045 : 0.0);
      const double fast_motion_score = std::clamp(
          (struct_motion_score * ego_weight) + flow_contribution, 0.0, 1.0);

      double slow_drift_score = 0.0;
      if (full_scene_slow_drift || sparse_scene_slow_drift) {
        const double drift_bonus =
            (static_cast<double>(win_flow.coherent_count) /
             static_cast<double>(kTotalBlocks)) *
            0.11 * win_flow.rigid_coherence;
        slow_drift_score = std::clamp(
            (struct_motion_score * 1.15 * win_flow.rigid_coherence) +
                drift_bonus,
            0.0, 1.0);
      }

      double motion_score = std::max(fast_motion_score, slow_drift_score);
      if (has_strong_static_anchors || looming_rejected) {
        motion_score = std::min(motion_score, active_threshold * 0.62);
      }
      if (oscillation_rejected) {
        motion_score = std::min(motion_score, active_threshold * 0.72);
      }

      const float base_adapt_rate = is_lighting_transient ? 0.30f : 0.06f;
      if (motion_score >= active_threshold) {
        consecutive_above_threshold += 1;
        for (size_t i = 0; i < count; ++i) {
          reference_grid[i] =
              (0.98f * reference_grid[i]) + (0.02f * current_grid[i]);
          previous_grid[i] = current_grid[i];
        }
      } else {
        consecutive_above_threshold = 0;
        for (int32_t gy = 0; gy < grid_h; ++gy) {
          const int32_t by =
              std::min(kBlocksY - 1, (gy * kBlocksY) / std::max(1, grid_h));
          for (int32_t gx = 0; gx < grid_w; ++gx) {
            const int32_t bx =
                std::min(kBlocksX - 1, (gx * kBlocksX) / std::max(1, grid_w));
            const int32_t b_idx = by * kBlocksX + bx;
            const int32_t px_count = block_pixel_count[b_idx];
            const double block_ref_score =
                px_count > 0
                    ? (block_ref_diff_sum[b_idx] /
                       static_cast<double>(px_count * 255))
                    : 0.0;
            float alpha = base_adapt_rate;
            if (settled_block_streak[b_idx] >= 4 && is_scene_presently_still) {
              alpha = 0.16f;
            } else if (has_strong_static_anchors &&
                       block_ref_score >= static_block_threshold) {
              alpha = 0.01f;
            }
            const size_t i =
                static_cast<size_t>(gy) * static_cast<size_t>(grid_w) +
                static_cast<size_t>(gx);
            reference_grid[i] =
                ((1.0f - alpha) * reference_grid[i]) + (alpha * current_grid[i]);
            previous_grid[i] = current_grid[i];
          }
        }
      }
      previous_mean_255 = curr_mean;
      recent_grids.push_back(current_grid);
      if (recent_grids.size() > 4) {
        recent_grids.pop_front();
      }

      const int32_t reported_coherent = std::max(
          coherent_translated_blocks,
          (full_scene_slow_drift || sparse_scene_slow_drift)
              ? win_flow.coherent_count
              : 0);

      if (consecutive_above_threshold >= persistence_frames) {
        char summary_buf[190];
        std::snprintf(
            summary_buf, sizeof(summary_buf),
            "Sustained camera movement detected (score %.3f >= threshold %.3f across %d frames)",
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
            {flutter::EncodableValue("coherentBlocks"),
             flutter::EncodableValue(reported_coherent)},
            {flutter::EncodableValue("anchoredBlocks"),
             flutter::EncodableValue(anchored_textured_blocks)},
            {flutter::EncodableValue("slowDriftScore"),
             flutter::EncodableValue(slow_drift_score)},
            {flutter::EncodableValue("loomingRejected"),
             flutter::EncodableValue(looming_rejected)},
            {flutter::EncodableValue("acPowerUnplugged"),
             flutter::EncodableValue(ac_power_unplugged_recently)},
            {flutter::EncodableValue("timestampMs"),
             flutter::EncodableValue(now_ms)},
        });
      } else if (processed_frame_count % 3 == 0) {
        char summary_buf[140];
        std::snprintf(summary_buf, sizeof(summary_buf),
                      "Camera motion score %.3f (threshold %.3f)", motion_score,
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
            {flutter::EncodableValue("coherentBlocks"),
             flutter::EncodableValue(reported_coherent)},
            {flutter::EncodableValue("anchoredBlocks"),
             flutter::EncodableValue(anchored_textured_blocks)},
            {flutter::EncodableValue("slowDriftScore"),
             flutter::EncodableValue(slow_drift_score)},
            {flutter::EncodableValue("loomingRejected"),
             flutter::EncodableValue(looming_rejected)},
            {flutter::EncodableValue("acPowerUnplugged"),
             flutter::EncodableValue(ac_power_unplugged_recently)},
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
  std::string paused_session_id_;
  std::atomic<bool> running_{false};
  std::atomic<double> motion_threshold_{0.095};
  std::thread worker_thread_;
};

// ============================================================================
// 5. Windows System Lifecycle, Lid Switch, Power & Non-Invasive HID Bridge
//    (`dev.watsafe/system_lifecycle` & `dev.watsafe/system_lifecycle_events`)
// ============================================================================

class WindowsSystemLifecycleBridge {
 public:
  WindowsSystemLifecycleBridge(HWND hwnd,
                               flutter::BinaryMessenger* messenger,
                               std::shared_ptr<MainThreadDispatcher> dispatcher)
      : hwnd_(hwnd), dispatcher_(std::move(dispatcher)) {
    method_channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            messenger, "dev.watsafe/system_lifecycle",
            &flutter::StandardMethodCodec::GetInstance());
    event_channel_ =
        std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
            messenger, "dev.watsafe/system_lifecycle_events",
            &flutter::StandardMethodCodec::GetInstance());

    method_channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) { HandleMethodCall(call, std::move(result)); });

    auto handler = std::make_unique<
        flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
        [this](const flutter::EncodableValue*,
               std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                   events)
            -> std::unique_ptr<flutter::StreamHandlerError<
                flutter::EncodableValue>> {
          event_sink_ = std::move(events);
          return nullptr;
        },
        [this](const flutter::EncodableValue*)
            -> std::unique_ptr<flutter::StreamHandlerError<
                flutter::EncodableValue>> {
          event_sink_.reset();
          return nullptr;
        });
    event_channel_->SetStreamHandler(std::move(handler));

    if (hwnd_ != nullptr) {
      lid_power_notify_ = ::RegisterPowerSettingNotification(
          hwnd_, &GUID_LIDSWITCH_STATE_CHANGE, DEVICE_NOTIFY_WINDOW_HANDLE);
    }
  }

  ~WindowsSystemLifecycleBridge() {
    StopInputPolling();
    if (lid_power_notify_ != nullptr) {
      ::UnregisterPowerSettingNotification(lid_power_notify_);
      lid_power_notify_ = nullptr;
    }
  }

  bool IsProtectionArmed() const { return armed_.load(); }

  void OnPowerBroadcast(WPARAM wparam, LPARAM lparam) {
    if (wparam == PBT_POWERSETTINGCHANGE && lparam != 0) {
      const auto* setting =
          reinterpret_cast<const POWERBROADCAST_SETTING*>(lparam);
      if (::IsEqualGUID(setting->PowerSetting, GUID_LIDSWITCH_STATE_CHANGE) &&
          setting->DataLength >= sizeof(DWORD)) {
        const DWORD lid_open =
            *reinterpret_cast<const DWORD*>(setting->Data);  // 0=closed, 1=open
        const bool closed = (lid_open == 0);
        has_observed_lid_switch_.store(true);
        const int prev = last_lid_state_.exchange(closed ? 0 : 1);
        if (prev == -1) {
          // Initial registration broadcast reflects current state; do not fire a transition.
          return;
        }
        if (prev != (closed ? 0 : 1)) {
          if (closed) {
            last_lid_close_ms_.store(CurrentTimeMillis());
            EmitLifecycleEvent(
                "lidClosed",
                "Protection interrupted — laptop lid closed while armed.",
                true);
          } else {
            EmitLifecycleEvent("lidOpened", "Laptop lid opened.", false);
          }
        }
      }
      return;
    }

    if (wparam == PBT_APMSUSPEND) {
      if (armed_.load()) {
        const bool recently_closed_lid =
            (last_lid_state_.load() == 0) &&
            (CurrentTimeMillis() - last_lid_close_ms_.load() > 1800);
        const bool known_closed = (last_lid_state_.load() == 0);
        if (CurrentTimeMillis() - last_lid_close_ms_.load() >= 1800) {
          EmitLifecycleEvent(
              recently_closed_lid ? "lidClosed" : "systemWillSleep",
              known_closed
                  ? "Protection interrupted — laptop lid closed while armed."
                  : "Protection interrupted — Windows PC is entering sleep while armed.",
              has_observed_lid_switch_.load()
                  ? std::optional<bool>(known_closed)
                  : std::nullopt);
        }
      }
      return;
    }

    if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) {
      EmitLifecycleEvent(
          "systemDidWake", "Windows PC resumed from sleep.",
          has_observed_lid_switch_.load()
              ? std::optional<bool>(last_lid_state_.load() == 0)
              : std::nullopt);
    }
  }

  void OnSystemShutdownOrLogoff() {
    if (armed_.load()) {
      EmitLifecycleEvent(
          "systemWillPowerOff",
          "Protection interrupted — Windows shutdown or sign-out started while armed.",
          std::nullopt);
    }
  }

  void OnAppCloseAttempted() {
    if (armed_.load()) {
      EmitLifecycleEvent(
          "appWillTerminate",
          "Protection interrupted — WATSafe close requested while armed.",
          std::nullopt);
    }
  }

 private:
  static bool GetBoolArg(const flutter::EncodableMap* map, const char* key,
                         bool fallback) {
    if (map == nullptr) {
      return fallback;
    }
    auto it = map->find(flutter::EncodableValue(key));
    if (it == map->end()) {
      return fallback;
    }
    if (const auto* b = std::get_if<bool>(&it->second)) {
      return *b;
    }
    return fallback;
  }

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto* args = GetArgsMap(call.arguments());
    const std::string& method = call.method_name();

    if (method == "getCapabilities") {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("isSupported"),
           flutter::EncodableValue(true)},
          {flutter::EncodableValue("supportsClamshellDetection"),
           flutter::EncodableValue(lid_power_notify_ != nullptr)},
          {flutter::EncodableValue("supportsSleepWakeNotifications"),
           flutter::EncodableValue(true)},
          {flutter::EncodableValue("supportsShutdownLogoutNotifications"),
           flutter::EncodableValue(true)},
          {flutter::EncodableValue("supportsQuitInterception"),
           flutter::EncodableValue(true)},
          {flutter::EncodableValue("supportsInputInteractionDetection"),
           flutter::EncodableValue(true)},
          {flutter::EncodableValue("platformLabel"),
           flutter::EncodableValue("Windows")},
      }));
      return;
    }

    if (method == "syncProtectionState") {
      const bool next_armed = GetBoolArg(args, "armed", false);
      const bool next_input =
          next_armed && GetBoolArg(args, "monitorInputInteraction", false);
      if (next_armed && !armed_.load()) {
        armed_since_ms_.store(CurrentTimeMillis());
      }
      armed_.store(next_armed);
      if (next_input) {
        StartInputPolling();
      } else {
        StopInputPolling();
      }
      result->Success();
      return;
    }

    if (method == "completeUrgentFlush") {
      result->Success();
      return;
    }

    result->NotImplemented();
  }

  void StartInputPolling() {
    if (polling_input_.exchange(true)) {
      return;
    }
    if (input_thread_.joinable()) {
      input_thread_.join();
    }
    input_thread_ = std::thread([this]() {
      DWORD baseline_tick = 0;
      LASTINPUTINFO initial_lii{};
      initial_lii.cbSize = sizeof(LASTINPUTINFO);
      if (::GetLastInputInfo(&initial_lii)) {
        baseline_tick = initial_lii.dwTime;
      }
      int64_t last_emit_ms = 0;
      while (polling_input_.load() && armed_.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(550));
        if (!polling_input_.load() || !armed_.load()) {
          break;
        }
        const int64_t now_ms = CurrentTimeMillis();
        if (now_ms - armed_since_ms_.load() < 1600) {
          LASTINPUTINFO settle_lii{};
          settle_lii.cbSize = sizeof(LASTINPUTINFO);
          if (::GetLastInputInfo(&settle_lii)) {
            baseline_tick = settle_lii.dwTime;
          }
          continue;
        }
        LASTINPUTINFO lii{};
        lii.cbSize = sizeof(LASTINPUTINFO);
        if (::GetLastInputInfo(&lii) && lii.dwTime != baseline_tick) {
          baseline_tick = lii.dwTime;
          if (now_ms - last_emit_ms >= 4000) {
            last_emit_ms = now_ms;
            EmitLifecycleEvent(
                "userInputDetected",
                "Keyboard or trackpad interaction detected while armed.",
                std::nullopt);
          }
        }
      }
    });
  }

  void StopInputPolling() {
    polling_input_.store(false);
    if (input_thread_.joinable()) {
      input_thread_.join();
    }
  }

  void EmitLifecycleEvent(const std::string& type, const std::string& summary,
                          std::optional<bool> clamshell_closed) {
    flutter::EncodableMap payload{
        {flutter::EncodableValue("type"), flutter::EncodableValue(type)},
        {flutter::EncodableValue("summary"), flutter::EncodableValue(summary)},
        {flutter::EncodableValue("timestampMs"),
         flutter::EncodableValue(CurrentTimeMillis())},
    };
    if (clamshell_closed.has_value()) {
      payload[flutter::EncodableValue("clamshellClosed")] =
          flutter::EncodableValue(*clamshell_closed);
    }
    dispatcher_->Post([this, payload = std::move(payload)]() {
      if (event_sink_) {
        event_sink_->Success(flutter::EncodableValue(payload));
      }
    });
  }

  HWND hwnd_ = nullptr;
  HPOWERNOTIFY lid_power_notify_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::shared_ptr<MainThreadDispatcher> dispatcher_;

  std::atomic<bool> armed_{false};
  std::atomic<bool> has_observed_lid_switch_{false};
  std::atomic<int> last_lid_state_{-1};
  std::atomic<int64_t> last_lid_close_ms_{0};
  std::atomic<int64_t> armed_since_ms_{0};
  std::atomic<bool> polling_input_{false};
  std::thread input_thread_;
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
        camera_bridge_(messenger, dispatcher_),
        lifecycle_bridge_(hwnd, messenger, dispatcher_) {}

  ~WindowsPlatformBridges() { dispatcher_->Shutdown(); }

  void DrainMainThreadTasks() { dispatcher_->DrainTasks(); }

  bool IsProtectionArmed() const {
    return lifecycle_bridge_.IsProtectionArmed();
  }

  void OnPowerBroadcast(WPARAM wparam, LPARAM lparam) {
    lifecycle_bridge_.OnPowerBroadcast(wparam, lparam);
    if (wparam == PBT_APMSUSPEND) {
      const bool armed = lifecycle_bridge_.IsProtectionArmed();
      accelerometer_bridge_.OnSystemSuspend(armed);
      camera_bridge_.OnSystemSuspend(armed);
    } else if (wparam == PBT_APMRESUMEAUTOMATIC ||
               wparam == PBT_APMRESUMESUSPEND) {
      accelerometer_bridge_.OnSystemResume();
      camera_bridge_.OnSystemResume();
    }
  }

  void OnSystemShutdownOrLogoff() {
    lifecycle_bridge_.OnSystemShutdownOrLogoff();
  }

  void OnAppCloseAttempted() { lifecycle_bridge_.OnAppCloseAttempted(); }

 private:
  std::shared_ptr<MainThreadDispatcher> dispatcher_;
  WindowsAudioAlarmBridge audio_bridge_;
  WindowsSecureStorageBridge secure_storage_bridge_;
  WindowsAccelerometerBridge accelerometer_bridge_;
  WindowsCameraMotionBridge camera_bridge_;
  WindowsSystemLifecycleBridge lifecycle_bridge_;
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
  // Handle bridge callbacks and OS power broadcasts before Flutter's top-level
  // window proc can consume them.
  if (message == kWmFlutterBridgeCallback) {
    if (bridges_) {
      bridges_->DrainMainThreadTasks();
    }
    return 0;
  }
  if (message == WM_POWERBROADCAST && bridges_) {
    bridges_->OnPowerBroadcast(wparam, lparam);
  }
  if ((message == WM_QUERYENDSESSION || message == WM_ENDSESSION) && bridges_) {
    bridges_->OnSystemShutdownOrLogoff();
  }
  if (message == WM_CLOSE && bridges_ && bridges_->IsProtectionArmed()) {
    // Minimize instead of silently terminating an armed session, and notify Dart.
    ::ShowWindow(hwnd, SW_MINIMIZE);
    return 0;
  }

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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
