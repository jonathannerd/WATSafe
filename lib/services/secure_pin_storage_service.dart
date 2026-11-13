import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/contracts/platform_contracts.dart';
import 'local_storage_service.dart';

/// Platform secure-storage adapter for salted PBKDF2 PIN records.
///
/// Uses the native `dev.watsafe/secure_storage` channel on macOS (Keychain with
/// restricted sandboxed Application Support fallback for ad-hoc signed builds),
/// Windows (DPAPI `CryptProtectData`), Android (Android Keystore AES-256-GCM),
/// and iOS (Keychain Services `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`),
/// falling back to restricted local storage when native channels are unavailable.
class PlatformSecurePinStorage implements SecurePinStorageAdapter {
  PlatformSecurePinStorage({
    MethodChannel? channel,
    Directory? fallbackDirectory,
    bool? supportsNativeChannelOverride,
  }) : _channel = channel ?? const MethodChannel('dev.watsafe/secure_storage'),
       _fallbackDirectory = fallbackDirectory,
       _supportsNativeChannelOverride = supportsNativeChannelOverride;

  final MethodChannel _channel;
  final Directory? _fallbackDirectory;
  final bool? _supportsNativeChannelOverride;
  static const String _fallbackBackendDescription =
      'Local Restricted Storage (0600 PBKDF2-SHA256)';
  String _backendUsed = _defaultBackendDescription();

  static String _defaultBackendDescription() {
    if (kIsWeb) {
      return 'Local Restricted Storage (PBKDF2-SHA256)';
    }
    if (Platform.isWindows) {
      return 'Windows DPAPI (CryptProtectData PBKDF2-HMAC-SHA256)';
    }
    if (Platform.isAndroid) {
      return 'Android Keystore (AES-256-GCM PBKDF2-HMAC-SHA256)';
    }
    if (Platform.isIOS) {
      return 'iOS Keychain Services (PBKDF2-HMAC-SHA256)';
    }
    return 'macOS Keychain / Restricted Application Support Adapter';
  }

  bool get _supportsNativeSecureChannel =>
      _supportsNativeChannelOverride ??
      (!kIsWeb &&
          (Platform.isMacOS ||
              Platform.isWindows ||
              Platform.isAndroid ||
              Platform.isIOS));

  @override
  String get storageBackendDescription => _backendUsed;

  @override
  Future<StoredPinRecord?> readPinRecord() async {
    if (_supportsNativeSecureChannel) {
      try {
        final raw = await _channel.invokeMethod<String>('readPinRecord');
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw) as Map<String, Object?>;
          if (_backendUsed == _fallbackBackendDescription) {
            _backendUsed = _defaultBackendDescription();
          }
          return StoredPinRecord.fromJson(decoded);
        }
      } on MissingPluginException {
        // Fall through to restricted file fallback
      } on PlatformException {
        // Fall through to restricted file fallback
      }
    }
    return _readFallbackFile();
  }

  @override
  Future<void> writePinRecord(StoredPinRecord record) async {
    final encoded = jsonEncode(record.toJson());
    if (_supportsNativeSecureChannel) {
      try {
        final backend = await _channel.invokeMethod<String>(
          'writePinRecord',
          <String, Object?>{'payload': encoded},
        );
        if (backend != null && backend.isNotEmpty) {
          _backendUsed = backend;
        } else {
          _backendUsed = _defaultBackendDescription();
        }
        await _deleteFallbackFileSafely();
        return;
      } on MissingPluginException {
        // Fall through to restricted file fallback
      } on PlatformException {
        // Fall through to restricted file fallback
      }
    }
    await _writeFallbackFile(encoded);
  }

  @override
  Future<void> deletePinRecord() async {
    if (_supportsNativeSecureChannel) {
      try {
        await _channel.invokeMethod<void>('deletePinRecord');
      } on MissingPluginException {
        // Ignore
      } on PlatformException {
        // Ignore
      }
    }
    await _deleteFallbackFileSafely();
  }

  Future<void> _deleteFallbackFileSafely() async {
    try {
      final file = await _resolveFallbackFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort cleanup of stale fallback file
    }
  }

  Future<StoredPinRecord?> _readFallbackFile() async {
    final file = await _resolveFallbackFile();
    if (!await file.exists()) {
      return null;
    }
    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      return null;
    }
    final map = jsonDecode(content) as Map<String, Object?>;
    _backendUsed = _fallbackBackendDescription;
    return StoredPinRecord.fromJson(map);
  }

  Future<void> _writeFallbackFile(
    String encoded, {
    bool updateBackendLabel = true,
  }) async {
    final file = await _resolveFallbackFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(encoded, flush: true);
    if (!kIsWeb && (Platform.isMacOS || Platform.isLinux)) {
      try {
        await Process.run('chmod', <String>['600', file.path]);
      } catch (_) {
        // Best-effort POSIX permission tightening
      }
    }
    if (updateBackendLabel) {
      _backendUsed = _fallbackBackendDescription;
    }
  }

  Future<File> _resolveFallbackFile() async {
    final dir =
        _fallbackDirectory ?? await LocalAppDataPaths.resolveDirectory();
    return File('${dir.path}${Platform.pathSeparator}watsafe_pin_hash.json');
  }
}

/// In-memory implementation of [SecurePinStorageAdapter] for unit and widget tests.
class InMemorySecurePinStorage implements SecurePinStorageAdapter {
  StoredPinRecord? _record;

  @override
  String get storageBackendDescription =>
      'In-Memory Test Secure Storage (PBKDF2-HMAC-SHA256)';

  @override
  Future<StoredPinRecord?> readPinRecord() async => _record;

  @override
  Future<void> writePinRecord(StoredPinRecord record) async {
    _record = record;
  }

  @override
  Future<void> deletePinRecord() async {
    _record = null;
  }
}
