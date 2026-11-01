import 'dart:convert';
import 'dart:io';

import '../core/contracts/platform_contracts.dart';
import '../core/models/incident_models.dart';
import '../core/models/settings_models.dart';

/// Resolves the per-user application support directory across desktop and mobile
/// hosts without requiring external native plugins.
class LocalAppDataPaths {
  static Future<Directory> resolveDirectory() async {
    final env = Platform.environment;
    String basePath;

    if (Platform.isMacOS) {
      final home = env['HOME'] ?? Directory.current.path;
      basePath = '$home/Library/Application Support/dev.watsafe.temp.watsafe';
    } else if (Platform.isWindows) {
      final appData =
          env['APPDATA'] ?? env['LOCALAPPDATA'] ?? Directory.current.path;
      basePath = '$appData\\dev.watsafe.temp.watsafe';
    } else {
      final home = env['HOME'] ?? Directory.systemTemp.path;
      basePath = '$home/.watsafe';
    }

    final dir = Directory(basePath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}

/// JSON file-backed implementation of [IncidentStorageAdapter].
///
/// Privacy invariant: Only serializes [IncidentRecord] metadata—never camera
/// frames or PIN credentials.
class FileIncidentStorage implements IncidentStorageAdapter {
  FileIncidentStorage({Directory? directory}) : _directory = directory;

  final Directory? _directory;

  Future<File> _resolveFile() async {
    final dir = _directory ?? await LocalAppDataPaths.resolveDirectory();
    return File('${dir.path}${Platform.pathSeparator}incidents.json');
  }

  @override
  Future<List<IncidentRecord>> loadIncidents() async {
    final file = await _resolveFile();
    if (!await file.exists()) {
      return const <IncidentRecord>[];
    }
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return const <IncidentRecord>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const <IncidentRecord>[];
    }
    return decoded
        .whereType<Map<String, Object?>>()
        .map(IncidentRecord.fromJson)
        .toList(growable: false);
  }

  @override
  Future<void> saveIncident(IncidentRecord incident) async {
    final existing = await loadIncidents();
    final updated = <IncidentRecord>[
      incident,
      ...existing.where((item) => item.id != incident.id),
    ];
    await _writeAll(updated);
  }

  @override
  Future<void> updateIncident(IncidentRecord incident) async {
    final existing = await loadIncidents();
    var replaced = false;
    final updated = existing
        .map((item) {
          if (item.id == incident.id) {
            replaced = true;
            return incident;
          }
          return item;
        })
        .toList(growable: true);

    if (!replaced) {
      updated.insert(0, incident);
    }
    await _writeAll(updated);
  }

  @override
  Future<void> clearIncidents() async {
    final file = await _resolveFile();
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _writeAll(List<IncidentRecord> records) async {
    final file = await _resolveFile();
    await file.parent.create(recursive: true);
    final payload = jsonEncode(
      records.map((item) => item.toJson()).toList(growable: false),
    );
    await file.writeAsString(payload, flush: true);
  }
}

/// JSON file-backed implementation of [SettingsStorageAdapter].
class FileSettingsStorage implements SettingsStorageAdapter {
  FileSettingsStorage({Directory? directory}) : _directory = directory;

  final Directory? _directory;

  Future<File> _resolveFile() async {
    final dir = _directory ?? await LocalAppDataPaths.resolveDirectory();
    return File('${dir.path}${Platform.pathSeparator}settings.json');
  }

  @override
  Future<ProtectionSettings> loadSettings() async {
    final file = await _resolveFile();
    if (!await file.exists()) {
      return const ProtectionSettings();
    }
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return const ProtectionSettings();
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      return const ProtectionSettings();
    }
    return ProtectionSettings.fromJson(decoded);
  }

  @override
  Future<void> saveSettings(ProtectionSettings settings) async {
    final file = await _resolveFile();
    await file.parent.create(recursive: true);
    final payload = jsonEncode(settings.toJson());
    await file.writeAsString(payload, flush: true);
  }
}

/// In-memory [IncidentStorageAdapter] for unit and widget tests.
class InMemoryIncidentStorage implements IncidentStorageAdapter {
  final List<IncidentRecord> _records = <IncidentRecord>[];
  bool shouldThrowOnSave = false;
  bool shouldThrowOnUpdate = false;

  @override
  Future<List<IncidentRecord>> loadIncidents() async =>
      List<IncidentRecord>.unmodifiable(_records);

  @override
  Future<void> saveIncident(IncidentRecord incident) async {
    if (shouldThrowOnSave) {
      throw StateError('Simulated local incident storage save failure');
    }
    _records.removeWhere((item) => item.id == incident.id);
    _records.insert(0, incident);
  }

  @override
  Future<void> updateIncident(IncidentRecord incident) async {
    if (shouldThrowOnUpdate) {
      throw StateError('Simulated local incident storage update failure');
    }
    final index = _records.indexWhere((item) => item.id == incident.id);
    if (index >= 0) {
      _records[index] = incident;
    } else {
      _records.insert(0, incident);
    }
  }

  @override
  Future<void> clearIncidents() async {
    _records.clear();
  }
}

/// In-memory [SettingsStorageAdapter] for unit and widget tests.
class InMemorySettingsStorage implements SettingsStorageAdapter {
  InMemorySettingsStorage([ProtectionSettings? initial])
    : _settings = initial ?? const ProtectionSettings();

  ProtectionSettings _settings;

  @override
  Future<ProtectionSettings> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(ProtectionSettings settings) async {
    _settings = settings;
  }
}
