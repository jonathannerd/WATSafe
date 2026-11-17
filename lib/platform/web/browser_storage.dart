import 'dart:convert';

import 'package:web/web.dart' as web;

import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';
import '../../core/models/incident_models.dart';
import '../../core/models/settings_models.dart';

/// Keeps prototype data in the current browser profile and site origin.
class BrowserStorage
    implements
        SettingsStorageAdapter,
        IncidentStorageAdapter,
        SecurePinStorageAdapter {
  static const _settingsKey = 'watsafe.settings.v1';
  static const _incidentsKey = 'watsafe.incidents.v1';
  static const _pinKey = 'watsafe.pinHash.v1';

  @override
  String get storageBackendDescription => 'Browser storage (salted PIN hash)';

  Object? _read(String key) {
    final value = web.window.localStorage.getItem(key);
    return value == null ? null : jsonDecode(value);
  }

  void _write(String key, Object value) {
    web.window.localStorage.setItem(key, jsonEncode(value));
  }

  @override
  Future<ProtectionSettings> loadSettings() async {
    final Object? saved;
    try {
      saved = _read(_settingsKey);
    } catch (_) {
      return const ProtectionSettings(
        selectedDetector: DetectorType.browserCameraSceneMotion,
      );
    }
    final settings = saved is Map<String, Object?>
        ? ProtectionSettings.fromJson(saved)
        : const ProtectionSettings();
    return settings.copyWith(
      selectedDetector: DetectorType.browserCameraSceneMotion,
    );
  }

  @override
  Future<void> saveSettings(ProtectionSettings settings) async {
    _write(_settingsKey, settings.toJson());
  }

  @override
  Future<StoredPinRecord?> readPinRecord() async {
    final saved = _read(_pinKey);
    return saved is Map<String, Object?>
        ? StoredPinRecord.fromJson(saved)
        : null;
  }

  @override
  Future<void> writePinRecord(StoredPinRecord record) async {
    _write(_pinKey, record.toJson());
  }

  @override
  Future<void> deletePinRecord() async {
    web.window.localStorage.removeItem(_pinKey);
  }

  List<IncidentRecord> _readIncidents() {
    final saved = _read(_incidentsKey);
    if (saved is! List) {
      return <IncidentRecord>[];
    }
    return saved
        .whereType<Map<String, Object?>>()
        .map(IncidentRecord.fromJson)
        .toList();
  }

  @override
  Future<List<IncidentRecord>> loadIncidents() async => _readIncidents();

  @override
  Future<void> saveIncident(IncidentRecord incident) =>
      updateIncident(incident);

  @override
  Future<void> updateIncident(IncidentRecord incident) async {
    final incidents = _readIncidents();
    final index = incidents.indexWhere((item) => item.id == incident.id);
    if (index == -1) {
      incidents.insert(0, incident);
    } else {
      incidents[index] = incident;
    }
    _write(_incidentsKey, incidents.map((item) => item.toJson()).toList());
  }

  @override
  Future<void> clearIncidents() async {
    web.window.localStorage.removeItem(_incidentsKey);
  }
}
