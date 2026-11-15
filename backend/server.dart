import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:postgres/postgres.dart';

/// Session record representing a protected laptop host and its active short-lived
/// pairing invitation.
class RelaySessionRecord {
  RelaySessionRecord({
    required this.pairingSessionId,
    required this.hostDisplayName,
    required this.hostToken,
    required this.createdAtUtc,
    this.activePairingCode,
    this.codeExpiresAtUtc,
  });

  final String pairingSessionId;
  String hostDisplayName;
  final String hostToken;
  final DateTime createdAtUtc;
  String? activePairingCode;
  DateTime? codeExpiresAtUtc;
}

/// Companion phone bond linked to a specific [pairingSessionId].
class CompanionBondRecord {
  CompanionBondRecord({
    required this.bondId,
    required this.pairingSessionId,
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.companionToken,
    required this.pairedAtUtcIso,
    this.connected = true,
    this.pushChannelReady = true,
    this.revokedAtUtcIso,
    this.lastSeenAtUtcIso,
  });

  final String bondId;
  final String pairingSessionId;
  final String deviceId;
  final String displayName;
  final String platform;
  final String companionToken;
  final String pairedAtUtcIso;
  bool connected;
  final bool pushChannelReady;
  String? revokedAtUtcIso;
  String? lastSeenAtUtcIso;

  bool get isRevoked => revokedAtUtcIso != null;

  Map<String, Object?> toDeviceSummaryJson() {
    return <String, Object?>{
      'bondId': bondId,
      'pairingSessionId': pairingSessionId,
      'deviceId': deviceId,
      'displayName': displayName,
      'platform': platform,
      'pairedAtUtcIso': pairedAtUtcIso,
      'connected': connected,
      'pushChannelReady': pushChannelReady,
      if (lastSeenAtUtcIso != null) 'lastSeenAtUtcIso': lastSeenAtUtcIso,
    };
  }
}

/// Sanitized metadata-only alert scoped strictly to one [pairingSessionId].
class SessionAlertRecord {
  const SessionAlertRecord({
    required this.alertSeq,
    required this.pairingSessionId,
    required this.incidentId,
    required this.sessionId,
    required this.kind,
    required this.detectorType,
    required this.triggeredAtUtc,
    required this.triggerSummary,
    required this.createdAtUtc,
    this.peakMotionScore,
    this.hostDisplayName,
    this.isTest = false,
  });

  final int alertSeq;
  final String pairingSessionId;
  final String incidentId;
  final String sessionId;
  final String kind;
  final String detectorType;
  final String triggeredAtUtc;
  final String triggerSummary;
  final String createdAtUtc;
  final double? peakMotionScore;
  final String? hostDisplayName;
  final bool isTest;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'alertSeq': alertSeq,
      'pairingSessionId': pairingSessionId,
      'incidentId': incidentId,
      'sessionId': sessionId,
      'kind': kind,
      'detectorType': detectorType,
      'triggeredAtUtc': triggeredAtUtc,
      'triggerSummary': triggerSummary,
      'createdAtUtc': createdAtUtc,
      if (peakMotionScore != null) 'peakMotionScore': peakMotionScore,
      if (hostDisplayName != null) 'hostDisplayName': hostDisplayName,
      'isTest': isTest,
    };
  }
}

/// Persistence boundary for the WATSafe Relay Server.
abstract class RelayStore {
  String get backendName;
  String get redactedDescription;

  Future<void> initialize();
  Future<void> close();

  Future<void> saveSession(RelaySessionRecord session);
  Future<RelaySessionRecord?> findSessionById(String pairingSessionId);
  Future<RelaySessionRecord?> findSessionByHostToken(String hostToken);
  Future<RelaySessionRecord?> findSessionByPairingCode(String normalizedCode);

  Future<void> saveCompanionBond(CompanionBondRecord bond);
  Future<CompanionBondRecord?> findActiveBondByCompanionToken(
    String companionToken,
  );
  Future<List<CompanionBondRecord>> listActiveBondsForSession(
    String pairingSessionId,
  );
  Future<bool> revokeBond({
    required String pairingSessionId,
    required String deviceId,
  });

  Future<({SessionAlertRecord alert, bool deduplicated})> recordSessionAlert({
    required String pairingSessionId,
    required String incidentId,
    required String sessionId,
    required String kind,
    required String detectorType,
    required String triggeredAtUtc,
    required String triggerSummary,
    required String createdAtUtc,
    double? peakMotionScore,
    String? hostDisplayName,
    bool isTest = false,
  });

  Future<List<SessionAlertRecord>> listAlertsAfterSeq({
    required String pairingSessionId,
    required int afterSeq,
  });

  Future<int> latestAlertSeq(String pairingSessionId);
}

/// Default zero-configuration in-memory store for local runs and offline CI.
class InMemoryRelayStore implements RelayStore {
  final Map<String, RelaySessionRecord> _sessionsById =
      <String, RelaySessionRecord>{};
  final Map<String, CompanionBondRecord> _bondsById =
      <String, CompanionBondRecord>{};
  final Map<String, List<SessionAlertRecord>> _alertsBySession =
      <String, List<SessionAlertRecord>>{};
  final Map<String, int> _seqBySession = <String, int>{};

  @override
  String get backendName => 'memory';

  @override
  String get redactedDescription => 'in-memory session store';

  @override
  Future<void> initialize() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> saveSession(RelaySessionRecord session) async {
    _sessionsById[session.pairingSessionId] = session;
  }

  @override
  Future<RelaySessionRecord?> findSessionById(String pairingSessionId) async {
    return _sessionsById[pairingSessionId];
  }

  @override
  Future<RelaySessionRecord?> findSessionByHostToken(String hostToken) async {
    for (final session in _sessionsById.values) {
      if (session.hostToken == hostToken) {
        return session;
      }
    }
    return null;
  }

  @override
  Future<RelaySessionRecord?> findSessionByPairingCode(
    String normalizedCode,
  ) async {
    for (final session in _sessionsById.values) {
      if (session.activePairingCode == normalizedCode) {
        return session;
      }
    }
    return null;
  }

  @override
  Future<void> saveCompanionBond(CompanionBondRecord bond) async {
    _bondsById[bond.bondId] = bond;
  }

  @override
  Future<CompanionBondRecord?> findActiveBondByCompanionToken(
    String companionToken,
  ) async {
    for (final bond in _bondsById.values) {
      if (!bond.isRevoked && bond.companionToken == companionToken) {
        return bond;
      }
    }
    return null;
  }

  @override
  Future<List<CompanionBondRecord>> listActiveBondsForSession(
    String pairingSessionId,
  ) async {
    return _bondsById.values
        .where((b) => !b.isRevoked && b.pairingSessionId == pairingSessionId)
        .toList(growable: false);
  }

  @override
  Future<bool> revokeBond({
    required String pairingSessionId,
    required String deviceId,
  }) async {
    var revokedAny = false;
    final nowIso = DateTime.now().toUtc().toIso8601String();
    for (final bond in _bondsById.values) {
      if (!bond.isRevoked &&
          bond.pairingSessionId == pairingSessionId &&
          bond.deviceId == deviceId) {
        bond.revokedAtUtcIso = nowIso;
        bond.connected = false;
        revokedAny = true;
      }
    }
    return revokedAny;
  }

  @override
  Future<({SessionAlertRecord alert, bool deduplicated})> recordSessionAlert({
    required String pairingSessionId,
    required String incidentId,
    required String sessionId,
    required String kind,
    required String detectorType,
    required String triggeredAtUtc,
    required String triggerSummary,
    required String createdAtUtc,
    double? peakMotionScore,
    String? hostDisplayName,
    bool isTest = false,
  }) async {
    final list = _alertsBySession.putIfAbsent(
      pairingSessionId,
      () => <SessionAlertRecord>[],
    );
    for (final existing in list) {
      if (existing.incidentId == incidentId) {
        return (alert: existing, deduplicated: true);
      }
    }
    final nextSeq = (_seqBySession[pairingSessionId] ?? 0) + 1;
    _seqBySession[pairingSessionId] = nextSeq;
    final created = SessionAlertRecord(
      alertSeq: nextSeq,
      pairingSessionId: pairingSessionId,
      incidentId: incidentId,
      sessionId: sessionId,
      kind: kind,
      detectorType: detectorType,
      triggeredAtUtc: triggeredAtUtc,
      triggerSummary: triggerSummary,
      createdAtUtc: createdAtUtc,
      peakMotionScore: peakMotionScore,
      hostDisplayName: hostDisplayName,
      isTest: isTest,
    );
    list.add(created);
    return (alert: created, deduplicated: false);
  }

  @override
  Future<List<SessionAlertRecord>> listAlertsAfterSeq({
    required String pairingSessionId,
    required int afterSeq,
  }) async {
    final list =
        _alertsBySession[pairingSessionId] ?? const <SessionAlertRecord>[];
    return list.where((a) => a.alertSeq > afterSeq).toList(growable: false);
  }

  @override
  Future<int> latestAlertSeq(String pairingSessionId) async {
    return _seqBySession[pairingSessionId] ?? 0;
  }
}

/// Environment-configured PostgreSQL / Aiven store.
///
/// Credentials are read exclusively from backend environment variables
/// (`AIVEN_DATABASE_URL` or `DATABASE_URL`, plus optional `AIVEN_CA_CERT_PATH`
/// or `PGSSLROOTCERT`) and are never exposed to clients or logs.
class PostgresRelayStore implements RelayStore {
  PostgresRelayStore._({
    required Endpoint endpoint,
    required ConnectionSettings settings,
    required String redactedSummary,
    required String tablePrefix,
  }) : _endpoint = endpoint,
       _settings = settings,
       _redactedSummary = redactedSummary,
       _tablePrefix = _sanitizePrefix(tablePrefix);

  static PostgresRelayStore? fromEnvironment([
    Map<String, String>? environment,
  ]) {
    final env = environment ?? Platform.environment;
    final rawUrl = (env['AIVEN_DATABASE_URL'] ?? env['DATABASE_URL'] ?? '')
        .trim();
    if (rawUrl.isEmpty) {
      return null;
    }

    final uri = Uri.parse(rawUrl);
    if (uri.scheme != 'postgres' && uri.scheme != 'postgresql') {
      throw FormatException(
        'Database URL must start with postgres:// or postgresql:// (got ${uri.scheme}).',
      );
    }

    final host = uri.host;
    if (host.isEmpty) {
      throw const FormatException('Database URL is missing a hostname.');
    }
    final port = uri.hasPort ? uri.port : 5432;
    final database = uri.pathSegments.isNotEmpty
        ? uri.pathSegments.first
        : 'defaultdb';

    String? username;
    String? password;
    if (uri.userInfo.isNotEmpty) {
      final colonIdx = uri.userInfo.indexOf(':');
      if (colonIdx >= 0) {
        username = Uri.decodeComponent(uri.userInfo.substring(0, colonIdx));
        password = Uri.decodeComponent(uri.userInfo.substring(colonIdx + 1));
      } else {
        username = Uri.decodeComponent(uri.userInfo);
      }
    }

    final caCertPath = (env['AIVEN_CA_CERT_PATH'] ?? env['PGSSLROOTCERT'] ?? '')
        .trim();
    final sslModeParam = (uri.queryParameters['sslmode'] ?? '')
        .trim()
        .toLowerCase();

    SecurityContext? securityContext;
    SslMode sslMode;
    if (caCertPath.isNotEmpty) {
      securityContext = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificates(caCertPath);
      sslMode = SslMode.verifyFull;
    } else if (sslModeParam == 'disable') {
      sslMode = SslMode.disable;
    } else if (sslModeParam == 'verify-full' || sslModeParam == 'verify-ca') {
      sslMode = SslMode.verifyFull;
    } else {
      sslMode = SslMode.require;
    }

    final endpoint = Endpoint(
      host: host,
      port: port,
      database: database,
      username: username,
      password: password,
    );
    final settings = ConnectionSettings(
      applicationName: 'watsafe_relay',
      connectTimeout: const Duration(seconds: 12),
      queryTimeout: const Duration(seconds: 12),
      sslMode: sslMode,
      securityContext: securityContext,
    );
    final userLabel = (username == null || username.isEmpty)
        ? 'postgres'
        : username;
    final redacted = 'postgres://$userLabel@$host:$port/$database';
    final prefix = env['WATSAFE_DB_TABLE_PREFIX'] ?? 'watsafe_';

    return PostgresRelayStore._(
      endpoint: endpoint,
      settings: settings,
      redactedSummary: redacted,
      tablePrefix: prefix,
    );
  }

  static String _sanitizePrefix(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
    return cleaned.isEmpty ? 'watsafe_' : cleaned;
  }

  final Endpoint _endpoint;
  final ConnectionSettings _settings;
  final String _redactedSummary;
  final String _tablePrefix;
  Connection? _connection;

  String get _sessionsTable => '${_tablePrefix}pairing_sessions';
  String get _bondsTable => '${_tablePrefix}companion_bonds';
  String get _alertsTable => '${_tablePrefix}session_alerts';

  @override
  String get backendName => 'aiven_postgres';

  @override
  String get redactedDescription => _redactedSummary;

  Future<Connection> _conn() async {
    final existing = _connection;
    if (existing != null && existing.isOpen) {
      return existing;
    }
    final opened = await Connection.open(_endpoint, settings: _settings);
    _connection = opened;
    return opened;
  }

  @override
  Future<void> initialize() async {
    final conn = await _conn();
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS $_sessionsTable (
        pairing_session_id TEXT PRIMARY KEY,
        host_display_name TEXT NOT NULL,
        host_token TEXT NOT NULL UNIQUE,
        active_pairing_code TEXT,
        code_expires_at_utc TIMESTAMPTZ,
        created_at_utc TIMESTAMPTZ NOT NULL
      )
    ''');
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS $_bondsTable (
        bond_id TEXT PRIMARY KEY,
        pairing_session_id TEXT NOT NULL REFERENCES $_sessionsTable(pairing_session_id) ON DELETE CASCADE,
        device_id TEXT NOT NULL,
        display_name TEXT NOT NULL,
        platform TEXT NOT NULL,
        companion_token TEXT NOT NULL UNIQUE,
        paired_at_utc_iso TEXT NOT NULL,
        connected BOOLEAN NOT NULL DEFAULT TRUE,
        push_channel_ready BOOLEAN NOT NULL DEFAULT TRUE,
        revoked_at_utc_iso TEXT,
        last_seen_at_utc_iso TEXT
      )
    ''');
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS $_alertsTable (
        pairing_session_id TEXT NOT NULL REFERENCES $_sessionsTable(pairing_session_id) ON DELETE CASCADE,
        alert_seq INTEGER NOT NULL,
        incident_id TEXT NOT NULL,
        session_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        detector_type TEXT NOT NULL,
        triggered_at_utc TEXT NOT NULL,
        trigger_summary TEXT NOT NULL,
        created_at_utc TEXT NOT NULL,
        peak_motion_score DOUBLE PRECISION,
        host_display_name TEXT,
        is_test BOOLEAN NOT NULL DEFAULT FALSE,
        PRIMARY KEY (pairing_session_id, alert_seq),
        UNIQUE (pairing_session_id, incident_id)
      )
    ''');
  }

  @override
  Future<void> close() async {
    final conn = _connection;
    _connection = null;
    if (conn != null && conn.isOpen) {
      await conn.close();
    }
  }

  RelaySessionRecord _rowToSession(Map<String, dynamic> map) {
    final createdRaw = map['created_at_utc'];
    final expiresRaw = map['code_expires_at_utc'];
    return RelaySessionRecord(
      pairingSessionId: map['pairing_session_id'] as String,
      hostDisplayName: map['host_display_name'] as String,
      hostToken: map['host_token'] as String,
      createdAtUtc: createdRaw is DateTime
          ? createdRaw.toUtc()
          : DateTime.parse('$createdRaw').toUtc(),
      activePairingCode: map['active_pairing_code'] as String?,
      codeExpiresAtUtc: expiresRaw == null
          ? null
          : (expiresRaw is DateTime
                ? expiresRaw.toUtc()
                : DateTime.tryParse('$expiresRaw')?.toUtc()),
    );
  }

  CompanionBondRecord _rowToBond(Map<String, dynamic> map) {
    return CompanionBondRecord(
      bondId: map['bond_id'] as String,
      pairingSessionId: map['pairing_session_id'] as String,
      deviceId: map['device_id'] as String,
      displayName: map['display_name'] as String,
      platform: map['platform'] as String,
      companionToken: map['companion_token'] as String,
      pairedAtUtcIso: map['paired_at_utc_iso'] as String,
      connected: map['connected'] as bool? ?? true,
      pushChannelReady: map['push_channel_ready'] as bool? ?? true,
      revokedAtUtcIso: map['revoked_at_utc_iso'] as String?,
      lastSeenAtUtcIso: map['last_seen_at_utc_iso'] as String?,
    );
  }

  SessionAlertRecord _rowToAlert(Map<String, dynamic> map) {
    return SessionAlertRecord(
      alertSeq: (map['alert_seq'] as num).toInt(),
      pairingSessionId: map['pairing_session_id'] as String,
      incidentId: map['incident_id'] as String,
      sessionId: map['session_id'] as String,
      kind: map['kind'] as String,
      detectorType: map['detector_type'] as String,
      triggeredAtUtc: map['triggered_at_utc'] as String,
      triggerSummary: map['trigger_summary'] as String,
      createdAtUtc: map['created_at_utc'] as String,
      peakMotionScore: (map['peak_motion_score'] as num?)?.toDouble(),
      hostDisplayName: map['host_display_name'] as String?,
      isTest: map['is_test'] as bool? ?? false,
    );
  }

  @override
  Future<void> saveSession(RelaySessionRecord session) async {
    final conn = await _conn();
    await conn.execute(
      Sql.named('''
        INSERT INTO $_sessionsTable (
          pairing_session_id,
          host_display_name,
          host_token,
          active_pairing_code,
          code_expires_at_utc,
          created_at_utc
        ) VALUES (
          @id,
          @name,
          @token,
          @code,
          @expires,
          @created
        )
        ON CONFLICT (pairing_session_id) DO UPDATE SET
          host_display_name = EXCLUDED.host_display_name,
          active_pairing_code = EXCLUDED.active_pairing_code,
          code_expires_at_utc = EXCLUDED.code_expires_at_utc
      '''),
      parameters: <String, Object?>{
        'id': session.pairingSessionId,
        'name': session.hostDisplayName,
        'token': session.hostToken,
        'code': session.activePairingCode,
        'expires': session.codeExpiresAtUtc,
        'created': session.createdAtUtc,
      },
    );
  }

  @override
  Future<RelaySessionRecord?> findSessionById(String pairingSessionId) async {
    final conn = await _conn();
    final rows = await conn.execute(
      Sql.named(
        'SELECT * FROM $_sessionsTable WHERE pairing_session_id = @id LIMIT 1',
      ),
      parameters: <String, Object?>{'id': pairingSessionId},
    );
    if (rows.isEmpty) {
      return null;
    }
    return _rowToSession(rows.first.toColumnMap());
  }

  @override
  Future<RelaySessionRecord?> findSessionByHostToken(String hostToken) async {
    final conn = await _conn();
    final rows = await conn.execute(
      Sql.named(
        'SELECT * FROM $_sessionsTable WHERE host_token = @token LIMIT 1',
      ),
      parameters: <String, Object?>{'token': hostToken},
    );
    if (rows.isEmpty) {
      return null;
    }
    return _rowToSession(rows.first.toColumnMap());
  }

  @override
  Future<RelaySessionRecord?> findSessionByPairingCode(
    String normalizedCode,
  ) async {
    final conn = await _conn();
    final rows = await conn.execute(
      Sql.named(
        'SELECT * FROM $_sessionsTable WHERE active_pairing_code = @code LIMIT 1',
      ),
      parameters: <String, Object?>{'code': normalizedCode},
    );
    if (rows.isEmpty) {
      return null;
    }
    return _rowToSession(rows.first.toColumnMap());
  }

  @override
  Future<void> saveCompanionBond(CompanionBondRecord bond) async {
    final conn = await _conn();
    await conn.execute(
      Sql.named('''
        INSERT INTO $_bondsTable (
          bond_id,
          pairing_session_id,
          device_id,
          display_name,
          platform,
          companion_token,
          paired_at_utc_iso,
          connected,
          push_channel_ready,
          revoked_at_utc_iso,
          last_seen_at_utc_iso
        ) VALUES (
          @bondId,
          @sessionId,
          @deviceId,
          @displayName,
          @platform,
          @companionToken,
          @pairedAt,
          @connected,
          @pushReady,
          @revokedAt,
          @lastSeen
        )
        ON CONFLICT (bond_id) DO UPDATE SET
          connected = EXCLUDED.connected,
          revoked_at_utc_iso = EXCLUDED.revoked_at_utc_iso,
          last_seen_at_utc_iso = EXCLUDED.last_seen_at_utc_iso
      '''),
      parameters: <String, Object?>{
        'bondId': bond.bondId,
        'sessionId': bond.pairingSessionId,
        'deviceId': bond.deviceId,
        'displayName': bond.displayName,
        'platform': bond.platform,
        'companionToken': bond.companionToken,
        'pairedAt': bond.pairedAtUtcIso,
        'connected': bond.connected,
        'pushReady': bond.pushChannelReady,
        'revokedAt': bond.revokedAtUtcIso,
        'lastSeen': bond.lastSeenAtUtcIso,
      },
    );
  }

  @override
  Future<CompanionBondRecord?> findActiveBondByCompanionToken(
    String companionToken,
  ) async {
    final conn = await _conn();
    final rows = await conn.execute(
      Sql.named('''
        SELECT * FROM $_bondsTable
        WHERE companion_token = @token AND revoked_at_utc_iso IS NULL
        LIMIT 1
      '''),
      parameters: <String, Object?>{'token': companionToken},
    );
    if (rows.isEmpty) {
      return null;
    }
    return _rowToBond(rows.first.toColumnMap());
  }

  @override
  Future<List<CompanionBondRecord>> listActiveBondsForSession(
    String pairingSessionId,
  ) async {
    final conn = await _conn();
    final rows = await conn.execute(
      Sql.named('''
        SELECT * FROM $_bondsTable
        WHERE pairing_session_id = @sessionId AND revoked_at_utc_iso IS NULL
        ORDER BY paired_at_utc_iso ASC
      '''),
      parameters: <String, Object?>{'sessionId': pairingSessionId},
    );
    return rows.map((r) => _rowToBond(r.toColumnMap())).toList(growable: false);
  }

  @override
  Future<bool> revokeBond({
    required String pairingSessionId,
    required String deviceId,
  }) async {
    final conn = await _conn();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final res = await conn.execute(
      Sql.named('''
        UPDATE $_bondsTable
        SET revoked_at_utc_iso = @nowIso, connected = FALSE
        WHERE pairing_session_id = @sessionId
          AND device_id = @deviceId
          AND revoked_at_utc_iso IS NULL
      '''),
      parameters: <String, Object?>{
        'nowIso': nowIso,
        'sessionId': pairingSessionId,
        'deviceId': deviceId,
      },
    );
    return res.affectedRows > 0;
  }

  @override
  Future<({SessionAlertRecord alert, bool deduplicated})> recordSessionAlert({
    required String pairingSessionId,
    required String incidentId,
    required String sessionId,
    required String kind,
    required String detectorType,
    required String triggeredAtUtc,
    required String triggerSummary,
    required String createdAtUtc,
    double? peakMotionScore,
    String? hostDisplayName,
    bool isTest = false,
  }) async {
    final conn = await _conn();
    return conn.runTx((tx) async {
      final existing = await tx.execute(
        Sql.named('''
          SELECT * FROM $_alertsTable
          WHERE pairing_session_id = @sessionId AND incident_id = @incidentId
          LIMIT 1
        '''),
        parameters: <String, Object?>{
          'sessionId': pairingSessionId,
          'incidentId': incidentId,
        },
      );
      if (existing.isNotEmpty) {
        return (
          alert: _rowToAlert(existing.first.toColumnMap()),
          deduplicated: true,
        );
      }

      final seqRows = await tx.execute(
        Sql.named('''
          SELECT COALESCE(MAX(alert_seq), 0) + 1 AS next_seq
          FROM $_alertsTable
          WHERE pairing_session_id = @sessionId
        '''),
        parameters: <String, Object?>{'sessionId': pairingSessionId},
      );
      final nextSeq =
          (seqRows.first.toColumnMap()['next_seq'] as num?)?.toInt() ?? 1;

      await tx.execute(
        Sql.named('''
          INSERT INTO $_alertsTable (
            pairing_session_id,
            alert_seq,
            incident_id,
            session_id,
            kind,
            detector_type,
            triggered_at_utc,
            trigger_summary,
            created_at_utc,
            peak_motion_score,
            host_display_name,
            is_test
          ) VALUES (
            @pairingSessionId,
            @alertSeq,
            @incidentId,
            @sessionId,
            @kind,
            @detectorType,
            @triggeredAtUtc,
            @triggerSummary,
            @createdAtUtc,
            @peakMotionScore,
            @hostDisplayName,
            @isTest
          )
        '''),
        parameters: <String, Object?>{
          'pairingSessionId': pairingSessionId,
          'alertSeq': nextSeq,
          'incidentId': incidentId,
          'sessionId': sessionId,
          'kind': kind,
          'detectorType': detectorType,
          'triggeredAtUtc': triggeredAtUtc,
          'triggerSummary': triggerSummary,
          'createdAtUtc': createdAtUtc,
          'peakMotionScore': peakMotionScore,
          'hostDisplayName': hostDisplayName,
          'isTest': isTest,
        },
      );

      return (
        alert: SessionAlertRecord(
          alertSeq: nextSeq,
          pairingSessionId: pairingSessionId,
          incidentId: incidentId,
          sessionId: sessionId,
          kind: kind,
          detectorType: detectorType,
          triggeredAtUtc: triggeredAtUtc,
          triggerSummary: triggerSummary,
          createdAtUtc: createdAtUtc,
          peakMotionScore: peakMotionScore,
          hostDisplayName: hostDisplayName,
          isTest: isTest,
        ),
        deduplicated: false,
      );
    });
  }

  @override
  Future<List<SessionAlertRecord>> listAlertsAfterSeq({
    required String pairingSessionId,
    required int afterSeq,
  }) async {
    final conn = await _conn();
    final rows = await conn.execute(
      Sql.named('''
        SELECT * FROM $_alertsTable
        WHERE pairing_session_id = @sessionId AND alert_seq > @afterSeq
        ORDER BY alert_seq ASC
      '''),
      parameters: <String, Object?>{
        'sessionId': pairingSessionId,
        'afterSeq': afterSeq,
      },
    );
    return rows
        .map((r) => _rowToAlert(r.toColumnMap()))
        .toList(growable: false);
  }

  @override
  Future<int> latestAlertSeq(String pairingSessionId) async {
    final conn = await _conn();
    final rows = await conn.execute(
      Sql.named('''
        SELECT COALESCE(MAX(alert_seq), 0) AS max_seq
        FROM $_alertsTable
        WHERE pairing_session_id = @sessionId
      '''),
      parameters: <String, Object?>{'sessionId': pairingSessionId},
    );
    return (rows.first.toColumnMap()['max_seq'] as num?)?.toInt() ?? 0;
  }
}

/// Standalone WATSafe REST Relay Server implementing session-scoped pairing,
/// live companion phone alert polling, strict privacy & credential filtering,
/// and optional Aiven PostgreSQL persistence via environment variables.
class WatSafeRelayServer {
  WatSafeRelayServer({
    RelayStore? store,
    DateTime Function()? clock,
    this.pairingCodeTtl = const Duration(minutes: 5),
  }) : _store = store ?? InMemoryRelayStore(),
       _clock = clock ?? DateTime.now;

  /// Creates a relay server backed by Aiven PostgreSQL when `AIVEN_DATABASE_URL`
  /// or `DATABASE_URL` is set in [environment], or falls back to
  /// [InMemoryRelayStore] for zero-config local runs.
  factory WatSafeRelayServer.fromEnvironment({
    Map<String, String>? environment,
    DateTime Function()? clock,
    Duration pairingCodeTtl = const Duration(minutes: 5),
  }) {
    final pgStore = PostgresRelayStore.fromEnvironment(environment);
    return WatSafeRelayServer(
      store: pgStore ?? InMemoryRelayStore(),
      clock: clock,
      pairingCodeTtl: pairingCodeTtl,
    );
  }

  static const String _codeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

  final RelayStore _store;
  final DateTime Function() _clock;
  final Duration pairingCodeTtl;
  final Random _random = Random.secure();

  HttpServer? _server;
  int _seq = 0;

  final List<Map<String, Object?>> _registeredDevices =
      <Map<String, Object?>>[];
  final List<Map<String, Object?>> _pairedDevicesSnapshot =
      <Map<String, Object?>>[];
  final Map<String, Map<String, Object?>> _reportedIncidentsSnapshot =
      <String, Map<String, Object?>>{};

  int get port => _server?.port ?? 0;
  String get storageBackend => _store.backendName;
  String get storageDescription => _store.redactedDescription;

  List<Map<String, Object?>> get pairedDevices =>
      List<Map<String, Object?>>.unmodifiable(_pairedDevicesSnapshot);
  List<Map<String, Object?>> get reportedIncidents =>
      List<Map<String, Object?>>.unmodifiable(
        _reportedIncidentsSnapshot.values,
      );

  static String normalizePairingCode(String raw) {
    return raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  Future<int> start({InternetAddress? address, int port = 8787}) async {
    await _store.initialize();
    final bindAddress = address ?? InternetAddress.loopbackIPv4;
    final server = await HttpServer.bind(bindAddress, port);
    _server = server;
    server.listen(_handleRequest);
    return server.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    await _store.close();
  }

  String _randomHex(int byteCount) {
    final bytes = List<int>.generate(byteCount, (_) => _random.nextInt(256));
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  String _generatePairingCode() {
    final chars = List<String>.generate(
      6,
      (_) => _codeAlphabet[_random.nextInt(_codeAlphabet.length)],
    );
    return '${chars.sublist(0, 3).join()}-${chars.sublist(3).join()}';
  }

  String? _extractBearerToken(HttpRequest request) {
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (auth == null) {
      return null;
    }
    final trimmed = auth.trim();
    if (trimmed.length > 7 && trimmed.toLowerCase().startsWith('bearer ')) {
      final token = trimmed.substring(7).trim();
      return token.isEmpty ? null : token;
    }
    return null;
  }

  /// Recursively inspects JSON keys and string values to block camera frames,
  /// images, PINs/PIN hashes, and database credentials from ever crossing or
  /// persisting through the relay.
  static String? detectForbiddenSensitiveField(
    Object? node, [
    String path = '',
  ]) {
    if (node is Map) {
      for (final entry in node.entries) {
        final rawKey = '${entry.key}';
        final lowerKey = rawKey.toLowerCase().replaceAll(
          RegExp(r'[^a-z0-9]'),
          '',
        );
        final nextPath = path.isEmpty ? rawKey : '$path.$rawKey';
        if (_isForbiddenNormalizedKey(lowerKey)) {
          return nextPath;
        }
        final nested = detectForbiddenSensitiveField(entry.value, nextPath);
        if (nested != null) {
          return nested;
        }
      }
    } else if (node is List) {
      for (var i = 0; i < node.length; i++) {
        final nested = detectForbiddenSensitiveField(node[i], '$path[$i]');
        if (nested != null) {
          return nested;
        }
      }
    } else if (node is String) {
      final trimmed = node.trim().toLowerCase();
      if (trimmed.startsWith('postgres://') ||
          trimmed.startsWith('postgresql://') ||
          trimmed.startsWith('data:image/')) {
        return path.isEmpty ? '<value>' : path;
      }
    }
    return null;
  }

  static bool _isForbiddenNormalizedKey(String normalizedKey) {
    const exactOrSubstringBlocks = <String>[
      'frame',
      'frames',
      'framebytes',
      'rawframe',
      'cameraframe',
      'image',
      'images',
      'imagebytes',
      'jpeg',
      'jpg',
      'png',
      'webp',
      'bmp',
      'rgba',
      'bgra',
      'nv12',
      'yuy2',
      'uyvy',
      'i420',
      'pixelbuffer',
      'pixels',
      'videobytes',
      'pin',
      'pinhash',
      'pinsalt',
      'pbkdf2',
      'saltbase64',
      'hashbase64',
      'databaseurl',
      'aivendatabaseurl',
      'pgpassword',
      'connectionstring',
      'dbpassword',
      'privatekey',
      'serviceaccount',
    ];
    for (final blocked in exactOrSubstringBlocks) {
      if (normalizedKey == blocked || normalizedKey.contains(blocked)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _applyCorsHeaders(request.response);
    if (request.method.toUpperCase() == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    try {
      final path = request.uri.path;
      final method = request.method.toUpperCase();

      if (method == 'GET' && path == '/v1/health') {
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'status': 'ok',
          'storageBackend': _store.backendName,
          'deliveryMode': 'foreground_companion_poll',
        });
        return;
      }

      if (method == 'POST' && path == '/v1/devices/register') {
        final body = await _readJsonBody(request);
        final id = 'reg_${++_seq}_${_randomHex(6)}';
        final entry = <String, Object?>{
          'deviceId': id,
          'displayName': body['displayName'] ?? 'WATSafe Host',
          'platform': body['platform'] ?? 'unknown',
          'bearerToken': 'tok_${_randomHex(16)}',
          'registeredAtUtc': _clock().toUtc().toIso8601String(),
        };
        _registeredDevices.add(entry);
        _writeJson(request.response, HttpStatus.ok, entry);
        return;
      }

      if (method == 'POST' && path == '/v1/pairing/initiate') {
        final body = await _readJsonBody(request);
        final forbidden = detectForbiddenSensitiveField(body);
        if (forbidden != null) {
          _writePrivacyViolation(request.response, forbidden);
          return;
        }

        final nowUtc = _clock().toUtc();
        final expiresAtUtc = nowUtc.add(pairingCodeTtl);
        final displayCode = _generatePairingCode();
        final normalizedCode = normalizePairingCode(displayCode);
        final hostDisplayName =
            (body['hostDisplayName'] as String?)?.trim().isNotEmpty == true
            ? (body['hostDisplayName'] as String).trim()
            : 'WATSafe Laptop';

        RelaySessionRecord? session;
        final existingToken = _extractBearerToken(request);
        if (existingToken != null) {
          session = await _store.findSessionByHostToken(existingToken);
        }

        if (session != null) {
          session.hostDisplayName = hostDisplayName;
          session.activePairingCode = normalizedCode;
          session.codeExpiresAtUtc = expiresAtUtc;
          await _store.saveSession(session);
        } else {
          session = RelaySessionRecord(
            pairingSessionId: 'sess_${_randomHex(10)}',
            hostDisplayName: hostDisplayName,
            hostToken: 'host_${_randomHex(20)}',
            createdAtUtc: nowUtc,
            activePairingCode: normalizedCode,
            codeExpiresAtUtc: expiresAtUtc,
          );
          await _store.saveSession(session);
        }

        final requestedRelayUrl = (body['relayUrl'] as String?)?.trim();
        final fallbackOrigin =
            'http://${request.headers.host ?? "127.0.0.1:$port"}';
        final effectiveRelayUrl =
            (requestedRelayUrl != null && requestedRelayUrl.isNotEmpty)
            ? requestedRelayUrl
            : fallbackOrigin;
        final qrPayload =
            'watsafe://pair?relay=${Uri.encodeQueryComponent(effectiveRelayUrl)}'
            '&code=${Uri.encodeQueryComponent(displayCode)}'
            '&session=${Uri.encodeQueryComponent(session.pairingSessionId)}';

        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'pairingSessionId': session.pairingSessionId,
          'hostDisplayName': session.hostDisplayName,
          'hostToken': session.hostToken,
          'pairingCode': displayCode,
          'expiresInSeconds': pairingCodeTtl.inSeconds,
          'expiresAtUtc': expiresAtUtc.toIso8601String(),
          'qrPayload': qrPayload,
        });
        return;
      }

      if (method == 'POST' && path == '/v1/pairing/complete') {
        final body = await _readJsonBody(request);
        final forbidden = detectForbiddenSensitiveField(body);
        if (forbidden != null) {
          _writePrivacyViolation(request.response, forbidden);
          return;
        }

        final nowUtc = _clock().toUtc();
        final rawCode = (body['pairingCode'] as String?) ?? '';
        final normalizedCode = normalizePairingCode(rawCode);

        RelaySessionRecord? session;
        final hostToken = _extractBearerToken(request);
        if (hostToken != null) {
          // Authenticated host registering a device directly onto its own session.
          session = await _store.findSessionByHostToken(hostToken);
          if (session == null) {
            _writeJson(
              request.response,
              HttpStatus.unauthorized,
              <String, Object?>{
                'error': 'UNAUTHORIZED_HOST_SESSION',
                'message': 'Invalid host session bearer token.',
              },
            );
            return;
          }
          if (session.activePairingCode == normalizedCode) {
            session.activePairingCode = null;
            session.codeExpiresAtUtc = null;
            await _store.saveSession(session);
          }
        } else {
          // Companion phone pairing via short-lived single-use pairing code.
          if (normalizedCode.isEmpty) {
            _writeJson(
              request.response,
              HttpStatus.badRequest,
              <String, Object?>{
                'error': 'INVALID_OR_EXPIRED_PAIRING_CODE',
                'message': 'A valid short-lived pairing code is required.',
              },
            );
            return;
          }
          final candidate = await _store.findSessionByPairingCode(
            normalizedCode,
          );
          final expiresAt = candidate?.codeExpiresAtUtc;
          if (candidate == null ||
              expiresAt == null ||
              !nowUtc.isBefore(expiresAt)) {
            _writeJson(request.response, HttpStatus.badRequest, <
              String,
              Object?
            >{
              'error': 'INVALID_OR_EXPIRED_PAIRING_CODE',
              'message':
                  'Pairing code is invalid, expired, or has already been used.',
            });
            return;
          }
          session = candidate;
          // Consume single-use code immediately so a second session cannot reuse it.
          session.activePairingCode = null;
          session.codeExpiresAtUtc = null;
          await _store.saveSession(session);
        }

        final nowIso = nowUtc.toIso8601String();
        final bond = CompanionBondRecord(
          bondId: 'bond_${++_seq}_${_randomHex(6)}',
          pairingSessionId: session.pairingSessionId,
          deviceId: (body['deviceId'] as String?)?.trim().isNotEmpty == true
              ? (body['deviceId'] as String).trim()
              : 'dev_${_seq}_${_randomHex(4)}',
          displayName:
              (body['displayName'] as String?)?.trim().isNotEmpty == true
              ? (body['displayName'] as String).trim()
              : 'Companion Device',
          platform: (body['platform'] as String?)?.trim().isNotEmpty == true
              ? (body['platform'] as String).trim()
              : 'Android (FCM)',
          companionToken: 'comp_${_randomHex(20)}',
          pairedAtUtcIso: (body['pairedAtUtc'] as String?) ?? nowIso,
          connected: true,
          pushChannelReady: true,
          lastSeenAtUtcIso: nowIso,
        );

        await _store.saveCompanionBond(bond);
        final summaryJson = bond.toDeviceSummaryJson();
        _pairedDevicesSnapshot.add(summaryJson);

        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          ...summaryJson,
          'hostDisplayName': session.hostDisplayName,
          'companionToken': bond.companionToken,
          'deliveryMode': 'foreground_poll',
        });
        return;
      }

      if (method == 'GET' && path == '/v1/pairing/devices') {
        final hostToken = _extractBearerToken(request);
        if (hostToken == null) {
          _writeJson(
            request.response,
            HttpStatus.unauthorized,
            <String, Object?>{
              'error': 'UNAUTHORIZED_HOST_SESSION',
              'message': 'Missing host session bearer token.',
            },
          );
          return;
        }
        final session = await _store.findSessionByHostToken(hostToken);
        if (session == null) {
          _writeJson(
            request.response,
            HttpStatus.unauthorized,
            <String, Object?>{
              'error': 'UNAUTHORIZED_HOST_SESSION',
              'message': 'Unknown or expired host session token.',
            },
          );
          return;
        }
        final bonds = await _store.listActiveBondsForSession(
          session.pairingSessionId,
        );
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'pairingSessionId': session.pairingSessionId,
          'hostDisplayName': session.hostDisplayName,
          'devices': bonds
              .map((b) => b.toDeviceSummaryJson())
              .toList(growable: false),
        });
        return;
      }

      if (method == 'DELETE' && path.startsWith('/v1/pairing/devices/')) {
        final hostToken = _extractBearerToken(request);
        if (hostToken == null) {
          _writeJson(
            request.response,
            HttpStatus.unauthorized,
            <String, Object?>{
              'error': 'UNAUTHORIZED_HOST_SESSION',
              'message': 'Missing host session bearer token.',
            },
          );
          return;
        }
        final session = await _store.findSessionByHostToken(hostToken);
        if (session == null) {
          _writeJson(
            request.response,
            HttpStatus.unauthorized,
            <String, Object?>{
              'error': 'UNAUTHORIZED_HOST_SESSION',
              'message': 'Invalid host session bearer token.',
            },
          );
          return;
        }
        final deviceId = Uri.decodeComponent(
          path.substring('/v1/pairing/devices/'.length),
        );
        final revoked = await _store.revokeBond(
          pairingSessionId: session.pairingSessionId,
          deviceId: deviceId,
        );
        _pairedDevicesSnapshot.removeWhere(
          (item) =>
              item['pairingSessionId'] == session.pairingSessionId &&
              item['deviceId'] == deviceId,
        );
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'revoked': revoked,
          'deviceId': deviceId,
        });
        return;
      }

      if (method == 'POST' && path == '/v1/devices/command') {
        final body = await _readJsonBody(request);
        final forbidden = detectForbiddenSensitiveField(body);
        if (forbidden != null) {
          _writePrivacyViolation(request.response, forbidden);
          return;
        }
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'delivered': true,
          'commandId': 'cmd_${++_seq}',
          'deviceId': body['deviceId'],
          'command': body['command'],
        });
        return;
      }

      if (method == 'POST' && path == '/v1/incidents:report') {
        final body = await _readJsonBody(request);
        // 1. Enforce strict privacy & credential boundary FIRST.
        final forbidden = detectForbiddenSensitiveField(body);
        if (forbidden != null) {
          _writePrivacyViolation(request.response, forbidden);
          return;
        }

        // 2. Authenticate protected laptop host session.
        final hostToken = _extractBearerToken(request);
        if (hostToken == null) {
          _writeJson(request.response, HttpStatus.unauthorized, <
            String,
            Object?
          >{
            'error': 'UNAUTHORIZED_HOST_SESSION',
            'message':
                'Incident reports require an authenticated host session token.',
          });
          return;
        }
        final session = await _store.findSessionByHostToken(hostToken);
        if (session == null) {
          _writeJson(
            request.response,
            HttpStatus.unauthorized,
            <String, Object?>{
              'error': 'UNAUTHORIZED_HOST_SESSION',
              'message': 'Invalid host session token.',
            },
          );
          return;
        }

        final nowIso = _clock().toUtc().toIso8601String();
        final incidentId =
            (body['incidentId'] as String?)?.trim().isNotEmpty == true
            ? (body['incidentId'] as String).trim()
            : 'inc_${++_seq}_${_randomHex(4)}';
        final activeBonds = await _store.listActiveBondsForSession(
          session.pairingSessionId,
        );

        final recorded = await _store.recordSessionAlert(
          pairingSessionId: session.pairingSessionId,
          incidentId: incidentId,
          sessionId: (body['sessionId'] as String?) ?? 'unknown_session',
          kind: (body['kind'] as String?) ?? 'realDetectorTrigger',
          detectorType: (body['detectorType'] as String?) ?? 'unknown',
          triggeredAtUtc: (body['triggeredAtUtc'] as String?) ?? nowIso,
          triggerSummary:
              (body['triggerSummary'] as String?) ?? 'Laptop alarm triggered',
          createdAtUtc: nowIso,
          peakMotionScore: (body['peakMotionScore'] as num?)?.toDouble(),
          hostDisplayName: session.hostDisplayName,
          isTest: body['isTest'] as bool? ?? false,
        );

        final dedupKey = '${session.pairingSessionId}::$incidentId';
        if (!recorded.deduplicated) {
          _reportedIncidentsSnapshot[dedupKey] = recorded.alert.toJson();
        }

        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'delivered': true,
          'deduplicated': recorded.deduplicated,
          'pairingSessionId': session.pairingSessionId,
          'incidentId': incidentId,
          'alertSeq': recorded.alert.alertSeq,
          'dispatchedCount': activeBonds.length,
        });
        return;
      }

      if (method == 'GET' && path == '/v1/companion/alerts') {
        final companionToken = _extractBearerToken(request);
        if (companionToken == null) {
          _writeJson(
            request.response,
            HttpStatus.unauthorized,
            <String, Object?>{
              'error': 'UNAUTHORIZED_COMPANION_SESSION',
              'message': 'Missing companion session bearer token.',
            },
          );
          return;
        }
        final bond = await _store.findActiveBondByCompanionToken(
          companionToken,
        );
        if (bond == null) {
          _writeJson(
            request.response,
            HttpStatus.unauthorized,
            <String, Object?>{
              'error': 'UNAUTHORIZED_COMPANION_SESSION',
              'message':
                  'Companion session is unpaired, revoked, or unauthorized.',
            },
          );
          return;
        }

        bond.connected = true;
        bond.lastSeenAtUtcIso = _clock().toUtc().toIso8601String();
        await _store.saveCompanionBond(bond);

        final session = await _store.findSessionById(bond.pairingSessionId);
        final afterSeq =
            int.tryParse(request.uri.queryParameters['afterSeq'] ?? '0') ?? 0;
        final alerts = await _store.listAlertsAfterSeq(
          pairingSessionId: bond.pairingSessionId,
          afterSeq: afterSeq,
        );
        final latestSeq = await _store.latestAlertSeq(bond.pairingSessionId);

        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'pairingSessionId': bond.pairingSessionId,
          'hostDisplayName': session?.hostDisplayName ?? 'WATSafe Laptop',
          'deviceId': bond.deviceId,
          'connected': true,
          'deliveryMode': 'foreground_poll',
          'latestSeq': latestSeq,
          'alerts': alerts.map((a) => a.toJson()).toList(growable: false),
        });
        return;
      }

      _writeJson(request.response, HttpStatus.notFound, <String, Object?>{
        'error': 'NOT_FOUND',
        'path': path,
      });
    } catch (error) {
      _writeJson(
        request.response,
        HttpStatus.internalServerError,
        <String, Object?>{'error': 'INTERNAL_SERVER_ERROR', 'detail': '$error'},
      );
    }
  }

  void _writePrivacyViolation(HttpResponse response, String fieldPath) {
    _writeJson(response, HttpStatus.badRequest, <String, Object?>{
      'error': 'PRIVACY_INVARIANT_VIOLATION',
      'field': fieldPath,
      'message':
          'Payloads must never contain camera frames, images, PIN material, or database credentials.',
    });
  }

  void _applyCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set(
      'Access-Control-Allow-Methods',
      'GET, POST, DELETE, OPTIONS',
    );
    response.headers.set(
      'Access-Control-Allow-Headers',
      'Authorization, Content-Type',
    );
  }

  Future<Map<String, Object?>> _readJsonBody(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    if (raw.trim().isEmpty) {
      return <String, Object?>{};
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return Map<String, Object?>.from(decoded);
    }
    return <String, Object?>{};
  }

  void _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, Object?> body,
  ) {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    response.close();
  }
}

Future<void> main(List<String> args) async {
  final envPort = int.tryParse(Platform.environment['PORT'] ?? '');
  final port = args.isNotEmpty
      ? (int.tryParse(args.first) ?? envPort ?? 8787)
      : (envPort ?? 8787);
  final bindHostRaw = (Platform.environment['WATSAFE_BIND_HOST'] ?? '0.0.0.0')
      .trim();
  final bindAddress =
      InternetAddress.tryParse(bindHostRaw) ?? InternetAddress.anyIPv4;

  final server = WatSafeRelayServer.fromEnvironment();
  final boundPort = await server.start(address: bindAddress, port: port);
  stdout.writeln(
    'WATSafe Relay Server listening on http://${bindAddress.address}:$boundPort '
    '(storage: ${server.storageBackend} — ${server.storageDescription})',
  );
}
