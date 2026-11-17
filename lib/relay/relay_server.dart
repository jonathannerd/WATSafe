import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:postgres/postgres.dart';

import 'pwa_assets.dart';
import 'web_push.dart';

/// Session record representing a protected laptop host and its active short-lived
/// pairing invitation.
class RelaySessionRecord {
  RelaySessionRecord({
    required this.pairingSessionId,
    required this.hostDisplayName,
    required this.hostToken,
    required this.createdAtUtc,
    this.hostDeviceId,
    this.activePairingCode,
    this.codeExpiresAtUtc,
    this.failedCodeAttempts = 0,
    this.hostLastSeenAtUtc,
    this.hostDisconnectedAtUtc,
    this.hostProtectionState = 'off',
  });

  final String pairingSessionId;
  String hostDisplayName;
  final String hostToken;
  final DateTime createdAtUtc;
  String? hostDeviceId;
  String? activePairingCode;
  DateTime? codeExpiresAtUtc;
  int failedCodeAttempts;
  DateTime? hostLastSeenAtUtc;
  DateTime? hostDisconnectedAtUtc;
  String hostProtectionState;

  bool isHostOnlineAt(
    DateTime nowUtc, {
    Duration ttl = const Duration(seconds: 45),
  }) {
    if (hostDisconnectedAtUtc != null) {
      return false;
    }
    final seen = hostLastSeenAtUtc;
    if (seen == null) {
      return false;
    }
    return nowUtc.difference(seen) <= ttl;
  }

  void markHostSeen(
    DateTime nowUtc, {
    String? displayName,
    String? deviceId,
    String? protectionState,
  }) {
    hostLastSeenAtUtc = nowUtc;
    hostDisconnectedAtUtc = null;
    if (displayName != null && displayName.trim().isNotEmpty) {
      hostDisplayName = displayName.trim();
    }
    if (deviceId != null && deviceId.trim().isNotEmpty) {
      hostDeviceId = deviceId.trim();
    }
    if (protectionState != null && protectionState.trim().isNotEmpty) {
      hostProtectionState = protectionState.trim();
    }
  }

  Map<String, Object?> toStorageJson() {
    return <String, Object?>{
      'pairingSessionId': pairingSessionId,
      'hostDisplayName': hostDisplayName,
      'hostToken': hostToken,
      'createdAtUtc': createdAtUtc.toIso8601String(),
      'hostDeviceId': ?hostDeviceId,
      'activePairingCode': ?activePairingCode,
      'codeExpiresAtUtc': ?codeExpiresAtUtc?.toIso8601String(),
      'failedCodeAttempts': failedCodeAttempts,
      'hostLastSeenAtUtc': ?hostLastSeenAtUtc?.toIso8601String(),
      'hostDisconnectedAtUtc': ?hostDisconnectedAtUtc?.toIso8601String(),
      'hostProtectionState': hostProtectionState,
    };
  }

  factory RelaySessionRecord.fromStorageJson(Map<String, Object?> json) {
    final createdRaw = json['createdAtUtc'] as String? ?? '';
    final expiresRaw = json['codeExpiresAtUtc'] as String?;
    final lastSeenRaw = json['hostLastSeenAtUtc'] as String?;
    final disconnectedRaw = json['hostDisconnectedAtUtc'] as String?;
    return RelaySessionRecord(
      pairingSessionId: json['pairingSessionId'] as String? ?? '',
      hostDisplayName: json['hostDisplayName'] as String? ?? 'My Laptop',
      hostToken: json['hostToken'] as String? ?? '',
      createdAtUtc:
          DateTime.tryParse(createdRaw)?.toUtc() ?? DateTime.now().toUtc(),
      hostDeviceId: json['hostDeviceId'] as String?,
      activePairingCode: json['activePairingCode'] as String?,
      codeExpiresAtUtc: expiresRaw != null
          ? DateTime.tryParse(expiresRaw)?.toUtc()
          : null,
      failedCodeAttempts: (json['failedCodeAttempts'] as num?)?.toInt() ?? 0,
      hostLastSeenAtUtc: lastSeenRaw != null
          ? DateTime.tryParse(lastSeenRaw)?.toUtc()
          : null,
      hostDisconnectedAtUtc: disconnectedRaw != null
          ? DateTime.tryParse(disconnectedRaw)?.toUtc()
          : null,
      hostProtectionState: json['hostProtectionState'] as String? ?? 'off',
    );
  }
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
    this.previousCompanionToken,
    this.previousTokenGraceUntilUtc,
    this.tokenRefreshedAtUtcIso,
    this.connected = true,
    this.pushChannelReady = false,
    this.notificationsEnabled = false,
    this.notificationChannel = 'foreground_only',
    this.httpsReady = false,
    this.homeScreenInstalled = false,
    this.notificationPermission = 'default',
    this.pushSubscribed = false,
    this.backendPushRegistered = false,
    this.pushToken,
    this.webPushEndpoint,
    this.webPushP256dh,
    this.webPushAuth,
    this.subscribedVapidPublicKey,
    this.lastPushAttemptAtUtcIso,
    this.lastPushAcceptedAtUtcIso,
    this.lastPushStatusCode,
    this.lastPushErrorCode,
    this.lastReceiptAtUtcIso,
    this.lastReceiptIncidentId,
    this.lastReceiptSource,
    this.activeHandoffCode,
    this.handoffExpiresAtUtc,
    this.revokedAtUtcIso,
    this.lastSeenAtUtcIso,
  });

  final String bondId;
  final String pairingSessionId;
  final String deviceId;
  final String displayName;
  String platform;
  String companionToken;
  final String pairedAtUtcIso;
  String? previousCompanionToken;
  DateTime? previousTokenGraceUntilUtc;
  String? tokenRefreshedAtUtcIso;
  bool connected;
  bool pushChannelReady;
  bool notificationsEnabled;
  String notificationChannel;
  bool httpsReady;
  bool homeScreenInstalled;
  String notificationPermission;
  bool pushSubscribed;
  bool backendPushRegistered;
  String? pushToken;
  String? webPushEndpoint;
  String? webPushP256dh;
  String? webPushAuth;
  String? subscribedVapidPublicKey;
  String? lastPushAttemptAtUtcIso;
  String? lastPushAcceptedAtUtcIso;
  int? lastPushStatusCode;
  String? lastPushErrorCode;
  String? lastReceiptAtUtcIso;
  String? lastReceiptIncidentId;
  String? lastReceiptSource;
  String? activeHandoffCode;
  DateTime? handoffExpiresAtUtc;
  String? revokedAtUtcIso;
  String? lastSeenAtUtcIso;

  bool get isRevoked => revokedAtUtcIso != null;

  bool get pushSubscriptionNeedsRenewal =>
      lastPushStatusCode == 404 ||
      lastPushStatusCode == 410 ||
      lastPushErrorCode == 'VapidPkHashMismatch' ||
      lastPushErrorCode == 'BadWebPushToken' ||
      lastPushErrorCode == 'Unregistered' ||
      lastPushErrorCode == 'ExpiredSubscription';

  bool matchesCompanionToken(String candidate, DateTime nowUtc) {
    if (isRevoked || candidate.isEmpty) {
      return false;
    }
    if (companionToken == candidate) {
      return true;
    }
    final prev = previousCompanionToken;
    final graceUntil = previousTokenGraceUntilUtc;
    if (prev != null &&
        prev == candidate &&
        graceUntil != null &&
        nowUtc.isBefore(graceUntil)) {
      return true;
    }
    return false;
  }

  bool get hasValidWebPushSubscription =>
      webPushEndpoint != null &&
      webPushEndpoint!.isNotEmpty &&
      webPushP256dh != null &&
      webPushP256dh!.isNotEmpty &&
      webPushAuth != null &&
      webPushAuth!.isNotEmpty;

  void clearWebPushSubscription({bool clearErrorTelemetry = false}) {
    webPushEndpoint = null;
    webPushP256dh = null;
    webPushAuth = null;
    subscribedVapidPublicKey = null;
    pushSubscribed = false;
    backendPushRegistered = false;
    notificationsEnabled = false;
    pushChannelReady = false;
    if (clearErrorTelemetry) {
      lastPushStatusCode = null;
      lastPushErrorCode = null;
    }
    if (notificationChannel == 'web_push') {
      notificationChannel = 'foreground_only';
    }
  }

  /// Client-safe summary (never exposes [companionToken], [pushToken],
  /// [webPushEndpoint], [webPushP256dh], [webPushAuth], or [activeHandoffCode]).
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
      'notificationsEnabled': notificationsEnabled,
      'notificationChannel': notificationChannel,
      'httpsReady': httpsReady,
      'homeScreenInstalled': homeScreenInstalled,
      'notificationPermission': notificationPermission,
      'pushSubscribed': pushSubscribed,
      'backendPushRegistered': backendPushRegistered,
      'subscribedVapidPublicKey': ?subscribedVapidPublicKey,
      'pushSubscriptionNeedsRenewal': pushSubscriptionNeedsRenewal,
      'lastPushAttemptAtUtcIso': ?lastPushAttemptAtUtcIso,
      'lastPushAcceptedAtUtcIso': ?lastPushAcceptedAtUtcIso,
      'lastPushStatusCode': ?lastPushStatusCode,
      'lastPushErrorCode': ?lastPushErrorCode,
      'lastReceiptAtUtcIso': ?lastReceiptAtUtcIso,
      'lastReceiptIncidentId': ?lastReceiptIncidentId,
      'lastReceiptSource': ?lastReceiptSource,
      'lastSeenAtUtcIso': ?lastSeenAtUtcIso,
    };
  }

  Map<String, Object?> toStorageJson() {
    return <String, Object?>{
      'bondId': bondId,
      'pairingSessionId': pairingSessionId,
      'deviceId': deviceId,
      'displayName': displayName,
      'platform': platform,
      'companionToken': companionToken,
      'pairedAtUtcIso': pairedAtUtcIso,
      'previousCompanionToken': ?previousCompanionToken,
      'previousTokenGraceUntilUtc': ?previousTokenGraceUntilUtc
          ?.toIso8601String(),
      'tokenRefreshedAtUtcIso': ?tokenRefreshedAtUtcIso,
      'connected': connected,
      'pushChannelReady': pushChannelReady,
      'notificationsEnabled': notificationsEnabled,
      'notificationChannel': notificationChannel,
      'httpsReady': httpsReady,
      'homeScreenInstalled': homeScreenInstalled,
      'notificationPermission': notificationPermission,
      'pushSubscribed': pushSubscribed,
      'backendPushRegistered': backendPushRegistered,
      'pushToken': ?pushToken,
      'webPushEndpoint': ?webPushEndpoint,
      'webPushP256dh': ?webPushP256dh,
      'webPushAuth': ?webPushAuth,
      'subscribedVapidPublicKey': ?subscribedVapidPublicKey,
      'lastPushAttemptAtUtcIso': ?lastPushAttemptAtUtcIso,
      'lastPushAcceptedAtUtcIso': ?lastPushAcceptedAtUtcIso,
      'lastPushStatusCode': ?lastPushStatusCode,
      'lastPushErrorCode': ?lastPushErrorCode,
      'lastReceiptAtUtcIso': ?lastReceiptAtUtcIso,
      'lastReceiptIncidentId': ?lastReceiptIncidentId,
      'lastReceiptSource': ?lastReceiptSource,
      'activeHandoffCode': ?activeHandoffCode,
      'handoffExpiresAtUtc': ?handoffExpiresAtUtc?.toIso8601String(),
      'revokedAtUtcIso': ?revokedAtUtcIso,
      'lastSeenAtUtcIso': ?lastSeenAtUtcIso,
    };
  }

  factory CompanionBondRecord.fromStorageJson(Map<String, Object?> json) {
    final graceRaw = json['previousTokenGraceUntilUtc'] as String?;
    final handoffRaw = json['handoffExpiresAtUtc'] as String?;
    return CompanionBondRecord(
      bondId: json['bondId'] as String? ?? '',
      pairingSessionId: json['pairingSessionId'] as String? ?? '',
      deviceId: json['deviceId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? 'My Phone',
      platform: json['platform'] as String? ?? 'Phone',
      companionToken: json['companionToken'] as String? ?? '',
      pairedAtUtcIso: json['pairedAtUtcIso'] as String? ?? '',
      previousCompanionToken: json['previousCompanionToken'] as String?,
      previousTokenGraceUntilUtc: graceRaw != null
          ? DateTime.tryParse(graceRaw)?.toUtc()
          : null,
      tokenRefreshedAtUtcIso: json['tokenRefreshedAtUtcIso'] as String?,
      connected: json['connected'] as bool? ?? true,
      pushChannelReady: json['pushChannelReady'] as bool? ?? false,
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? false,
      notificationChannel:
          json['notificationChannel'] as String? ?? 'foreground_only',
      httpsReady: json['httpsReady'] as bool? ?? false,
      homeScreenInstalled: json['homeScreenInstalled'] as bool? ?? false,
      notificationPermission:
          json['notificationPermission'] as String? ?? 'default',
      pushSubscribed: json['pushSubscribed'] as bool? ?? false,
      backendPushRegistered: json['backendPushRegistered'] as bool? ?? false,
      pushToken: json['pushToken'] as String?,
      webPushEndpoint: json['webPushEndpoint'] as String?,
      webPushP256dh: json['webPushP256dh'] as String?,
      webPushAuth: json['webPushAuth'] as String?,
      subscribedVapidPublicKey: json['subscribedVapidPublicKey'] as String?,
      lastPushAttemptAtUtcIso: json['lastPushAttemptAtUtcIso'] as String?,
      lastPushAcceptedAtUtcIso: json['lastPushAcceptedAtUtcIso'] as String?,
      lastPushStatusCode: (json['lastPushStatusCode'] as num?)?.toInt(),
      lastPushErrorCode: json['lastPushErrorCode'] as String?,
      lastReceiptAtUtcIso: json['lastReceiptAtUtcIso'] as String?,
      lastReceiptIncidentId: json['lastReceiptIncidentId'] as String?,
      lastReceiptSource: json['lastReceiptSource'] as String?,
      activeHandoffCode: json['activeHandoffCode'] as String?,
      handoffExpiresAtUtc: handoffRaw != null
          ? DateTime.tryParse(handoffRaw)?.toUtc()
          : null,
      revokedAtUtcIso: json['revokedAtUtcIso'] as String?,
      lastSeenAtUtcIso: json['lastSeenAtUtcIso'] as String?,
    );
  }
}

/// Authenticated device location fix attached asynchronously to a [SessionAlertRecord].
class AlertLocationData {
  const AlertLocationData({
    required this.latitude,
    required this.longitude,
    required this.capturedAtUtc,
    this.accuracyMeters,
    this.isApproximate = false,
    this.isLastKnown = false,
  });

  final double latitude;
  final double longitude;
  final String capturedAtUtc;
  final double? accuracyMeters;
  final bool isApproximate;
  final bool isLastKnown;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'latitude': latitude,
      'longitude': longitude,
      'capturedAtUtc': capturedAtUtc,
      'accuracyMeters': ?accuracyMeters,
      'isApproximate': isApproximate,
      'isLastKnown': isLastKnown,
    };
  }

  factory AlertLocationData.fromJson(Map<String, Object?> json) {
    return AlertLocationData(
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      capturedAtUtc: json['capturedAtUtc'] as String? ?? '',
      accuracyMeters: (json['accuracyMeters'] as num?)?.toDouble(),
      isApproximate: json['isApproximate'] as bool? ?? false,
      isLastKnown: json['isLastKnown'] as bool? ?? false,
    );
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
    this.updatedSeq,
    this.peakMotionScore,
    this.hostDisplayName,
    this.isTest = false,
    this.location,
    this.locationStatus = 'notRequested',
    this.receiptConfirmedAtUtc,
    this.receiptSource,
  });

  final int alertSeq;
  final int? updatedSeq;
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
  final AlertLocationData? location;
  final String locationStatus;
  final String? receiptConfirmedAtUtc;
  final String? receiptSource;

  bool get isReceiptConfirmed =>
      receiptConfirmedAtUtc != null && receiptConfirmedAtUtc!.isNotEmpty;

  int get effectiveSeq =>
      updatedSeq != null && updatedSeq! > alertSeq ? updatedSeq! : alertSeq;

  SessionAlertRecord copyWith({
    int? updatedSeq,
    AlertLocationData? location,
    String? locationStatus,
    String? receiptConfirmedAtUtc,
    String? receiptSource,
  }) {
    return SessionAlertRecord(
      alertSeq: alertSeq,
      updatedSeq: updatedSeq ?? this.updatedSeq,
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
      location: location ?? this.location,
      locationStatus: locationStatus ?? this.locationStatus,
      receiptConfirmedAtUtc:
          receiptConfirmedAtUtc ?? this.receiptConfirmedAtUtc,
      receiptSource: receiptSource ?? this.receiptSource,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'alertSeq': alertSeq,
      'updatedSeq': ?updatedSeq,
      'pairingSessionId': pairingSessionId,
      'incidentId': incidentId,
      'sessionId': sessionId,
      'kind': kind,
      'detectorType': detectorType,
      'triggeredAtUtc': triggeredAtUtc,
      'triggerSummary': triggerSummary,
      'createdAtUtc': createdAtUtc,
      'peakMotionScore': ?peakMotionScore,
      'hostDisplayName': ?hostDisplayName,
      'isTest': isTest,
      if (location != null) 'location': location!.toJson(),
      'locationStatus': locationStatus,
      'receiptConfirmed': isReceiptConfirmed,
      'receiptConfirmedAtUtc': ?receiptConfirmedAtUtc,
      'receiptSource': ?receiptSource,
    };
  }

  factory SessionAlertRecord.fromJson(Map<String, Object?> json) {
    AlertLocationData? loc;
    final rawLoc = json['location'];
    if (rawLoc is Map) {
      loc = AlertLocationData.fromJson(Map<String, Object?>.from(rawLoc));
    }
    return SessionAlertRecord(
      alertSeq: (json['alertSeq'] as num?)?.toInt() ?? 0,
      updatedSeq: (json['updatedSeq'] as num?)?.toInt(),
      pairingSessionId: json['pairingSessionId'] as String? ?? '',
      incidentId: json['incidentId'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      kind: json['kind'] as String? ?? 'realDetectorTrigger',
      detectorType: json['detectorType'] as String? ?? 'unknown',
      triggeredAtUtc: json['triggeredAtUtc'] as String? ?? '',
      triggerSummary: json['triggerSummary'] as String? ?? '',
      createdAtUtc: json['createdAtUtc'] as String? ?? '',
      peakMotionScore: (json['peakMotionScore'] as num?)?.toDouble(),
      hostDisplayName: json['hostDisplayName'] as String?,
      isTest: json['isTest'] as bool? ?? false,
      location: loc,
      locationStatus: json['locationStatus'] as String? ?? 'notRequested',
      receiptConfirmedAtUtc: json['receiptConfirmedAtUtc'] as String?,
      receiptSource: json['receiptSource'] as String?,
    );
  }
}

/// Outbound lock-screen push payload (strictly device name + alarm message + incidentId;
/// NEVER coordinates, camera frames, or PINs).
class OutboundPushEnvelope {
  const OutboundPushEnvelope({
    required this.bondId,
    required this.deviceId,
    required this.platform,
    required this.notificationChannel,
    required this.title,
    required this.body,
    required this.incidentId,
    required this.pairingSessionId,
    required this.isTest,
    this.pushToken,
    this.webPushEndpoint,
  });

  final String bondId;
  final String deviceId;
  final String platform;
  final String notificationChannel;
  final String title;
  final String body;
  final String incidentId;
  final String pairingSessionId;
  final bool isTest;
  final String? pushToken;
  final String? webPushEndpoint;

  Map<String, Object?> toSafeMetadataJson() {
    return <String, Object?>{
      'bondId': bondId,
      'deviceId': deviceId,
      'platform': platform,
      'notificationChannel': notificationChannel,
      'title': title,
      'body': body,
      'data': <String, Object?>{
        'incidentId': incidentId,
        'pairingSessionId': pairingSessionId,
        'isTest': isTest,
      },
    };
  }
}

/// Structured outcome of attempting server-side push delivery to paired bonds.
///
/// Explicitly distinguishes "push service accepted" ([pushAcceptedCount] > 0)
/// from provider rejection ([pushFailedCount] > 0) and unconfigured web bonds
/// ([webBondsMissingPushCount] > 0). Confirmed phone receipt is tracked
/// separately when the phone Service Worker or app calls `/v1/companion/events/<id>/ack`.
class PushDispatchSummary {
  const PushDispatchSummary({
    required this.activeBondCount,
    required this.pushAttemptedCount,
    required this.pushAcceptedCount,
    required this.pushFailedCount,
    required this.webBondsMissingPushCount,
    this.failureReasons = const <String>[],
  });

  final int activeBondCount;
  final int pushAttemptedCount;
  final int pushAcceptedCount;
  final int pushFailedCount;
  final int webBondsMissingPushCount;
  final List<String> failureReasons;

  String get deliveryStage {
    if (pushAcceptedCount > 0) {
      return 'push_service_accepted';
    }
    if (pushFailedCount > 0) {
      return 'push_rejected';
    }
    if (webBondsMissingPushCount > 0) {
      return 'notifications_not_enabled';
    }
    if (activeBondCount > 0) {
      return 'companion_poll_queued';
    }
    return 'no_paired_phone';
  }
}

/// Server-side push provider adapter. Reads provider keys strictly from server
/// environment variables (or server-private local runtime key file) and never
/// exposes private keys to clients.
abstract class PushProviderAdapter {
  bool get isConfigured;
  String get providerSummary;
  String? get vapidPublicKey;
  String? get vapidSubject => null;

  Future<void> verifyConfiguredSenders() async {}

  Future<int> dispatchAlertToBonds({
    required List<CompanionBondRecord> bonds,
    required SessionAlertRecord alert,
    required String hostDisplayName,
    Future<void> Function(CompanionBondRecord expiredBond)?
    onBondSubscriptionExpired,
  });

  Future<PushDispatchSummary> dispatchAlertWithSummary({
    required List<CompanionBondRecord> bonds,
    required SessionAlertRecord alert,
    required String hostDisplayName,
    Future<void> Function(CompanionBondRecord updatedBond)? onBondUpdated,
    Future<void> Function(CompanionBondRecord expiredBond)?
    onBondSubscriptionExpired,
  }) async {
    final active = bonds.where((b) => !b.isRevoked).length;
    final accepted = await dispatchAlertToBonds(
      bonds: bonds,
      alert: alert,
      hostDisplayName: hostDisplayName,
      onBondSubscriptionExpired: onBondSubscriptionExpired,
    );
    return PushDispatchSummary(
      activeBondCount: active,
      pushAttemptedCount: accepted,
      pushAcceptedCount: accepted,
      pushFailedCount: 0,
      webBondsMissingPushCount: 0,
    );
  }
}

/// Server push dispatcher supporting:
/// - Built-in RFC 8030 + RFC 8291 (`aes128gcm`) + RFC 8292 (`ES256` VAPID) Web Push
/// - FCM HTTP v1 (`FCM_PROJECT_ID` + `FCM_BEARER_TOKEN`) or Legacy (`FCM_SERVER_KEY`)
/// - APNs HTTP/2 (`APNS_AUTH_TOKEN` + `APNS_BUNDLE_ID`, optional `APNS_USE_SANDBOX=true`)
/// - Verified Push Gateway Webhook (`WATSAFE_PUSH_WEBHOOK_URL`)
class EnvironmentPushProviderAdapter implements PushProviderAdapter {
  EnvironmentPushProviderAdapter({
    Map<String, String>? environment,
    this._customSender,
    bool persistVapidKeysToDisk = false,
    File? vapidKeyFile,
    this.logWebPushFailures = true,
  }) : _env = environment ?? Platform.environment {
    final envPriv = (_env['VAPID_PRIVATE_KEY'] ?? '').trim();
    final envPub = (_env['VAPID_PUBLIC_KEY'] ?? '').trim();
    _hasExplicitEnvVapidKey = envPriv.isNotEmpty || envPub.isNotEmpty;
    if (envPriv.isNotEmpty) {
      _vapidKeyPair = VapidKeyPair.fromBase64Url(
        privateKeyBase64Url: envPriv,
        publicKeyBase64Url: envPub.isEmpty ? null : envPub,
      );
      _publicKeyOverride = null;
    } else if (envPub.isNotEmpty) {
      // Preserve explicit VAPID_PUBLIC_KEY override (e.g., customSender tests)
      // while generating a real P-256 keypair if direct Web Push is used.
      _vapidKeyPair = VapidKeyPair.generate();
      _publicKeyOverride = envPub;
    } else {
      _vapidKeyPair = VapidKeyPair.loadOrCreate(
        environment: _env,
        keyFile: vapidKeyFile,
        persistToDisk: persistVapidKeysToDisk,
      );
      _publicKeyOverride = null;
    }
    _webPushSender = DirectWebPushSender(
      vapidKeyPair: _vapidKeyPair,
      vapidSubject: _vapidSubject,
      publicHttpsOrigin: _publicOriginHint,
      logFailuresToStderr: logWebPushFailures,
    );
  }

  final Map<String, String> _env;
  final Future<bool> Function(OutboundPushEnvelope envelope)? _customSender;
  final bool logWebPushFailures;
  late final bool _hasExplicitEnvVapidKey;
  late VapidKeyPair _vapidKeyPair;
  late final String? _publicKeyOverride;
  late DirectWebPushSender _webPushSender;
  final List<OutboundPushEnvelope> _sentEnvelopes = <OutboundPushEnvelope>[];

  /// Ensures VAPID keys survive container redeployments and backend restarts by
  /// synchronizing with [store] whenever env overrides are not set.
  Future<void> syncDurableVapidKeys(RelayStore store) async {
    if (_hasExplicitEnvVapidKey) {
      await store.savePersistedVapidKeys(
        publicKeyBase64Url: vapidPublicKey ?? _vapidKeyPair.publicKeyBase64Url,
        privateKeyBase64Url: _vapidKeyPair.privateKeyBase64Url,
      );
      return;
    }
    try {
      final stored = await store.loadPersistedVapidKeys();
      final storedPriv = stored?['privateKey']?.trim() ?? '';
      final storedPub = stored?['publicKey']?.trim();
      if (storedPriv.isNotEmpty) {
        _vapidKeyPair = VapidKeyPair.fromBase64Url(
          privateKeyBase64Url: storedPriv,
          publicKeyBase64Url: (storedPub != null && storedPub.isNotEmpty)
              ? storedPub
              : null,
        );
        _webPushSender = DirectWebPushSender(
          vapidKeyPair: _vapidKeyPair,
          vapidSubject: _vapidSubject,
          publicHttpsOrigin: _publicOriginHint,
          logFailuresToStderr: logWebPushFailures,
        );
        return;
      }
      await store.savePersistedVapidKeys(
        publicKeyBase64Url: _vapidKeyPair.publicKeyBase64Url,
        privateKeyBase64Url: _vapidKeyPair.privateKeyBase64Url,
      );
    } catch (_) {
      // Non-fatal: keep loaded/generated VAPID keypair
    }
  }

  bool? _webhookSenderVerified;

  List<OutboundPushEnvelope> get sentEnvelopes =>
      List<OutboundPushEnvelope>.unmodifiable(_sentEnvelopes);

  bool? get webhookSenderVerified => _webhookSenderVerified;

  String get _fcmProjectId => (_env['FCM_PROJECT_ID'] ?? '').trim();
  String get _fcmBearerToken => (_env['FCM_BEARER_TOKEN'] ?? '').trim();
  String get _fcmServerKey => (_env['FCM_SERVER_KEY'] ?? '').trim();
  String get _apnsAuthToken => (_env['APNS_AUTH_TOKEN'] ?? '').trim();
  String get _apnsBundleId => (_env['APNS_BUNDLE_ID'] ?? '').trim();
  bool get _apnsSandbox =>
      (_env['APNS_USE_SANDBOX'] ?? '').trim().toLowerCase() == 'true';
  String get _pushWebhookUrl => (_env['WATSAFE_PUSH_WEBHOOK_URL'] ?? '').trim();
  String? get _publicOriginHint {
    for (final key in const <String>[
      'WATSAFE_PUBLIC_URL',
      'RENDER_EXTERNAL_URL',
    ]) {
      final raw = (_env[key] ?? '').trim();
      if (raw.startsWith('https://')) {
        return raw;
      }
    }
    return null;
  }

  String get _vapidSubject => VapidKeyPair.normalizeSubject(
    _env['VAPID_SUBJECT'],
    publicHttpsOrigin: _publicOriginHint,
  );

  @override
  String? get vapidSubject => _vapidSubject;

  @override
  String? get vapidPublicKey =>
      _publicKeyOverride ?? _vapidKeyPair.publicKeyBase64Url;

  bool get _hasFcm =>
      (_fcmProjectId.isNotEmpty && _fcmBearerToken.isNotEmpty) ||
      _fcmServerKey.isNotEmpty;
  bool get _hasApns => _apnsAuthToken.isNotEmpty && _apnsBundleId.isNotEmpty;
  bool get _hasWebhook => _pushWebhookUrl.isNotEmpty;
  bool get _hasVerifiedWebhook =>
      _hasWebhook && _webhookSenderVerified != false;

  bool get directWebPushReady => vapidPublicKey != null;
  bool get hasWebhookConfigured => _hasWebhook;

  @override
  bool get isConfigured =>
      _customSender != null ||
      _hasFcm ||
      _hasApns ||
      _hasVerifiedWebhook ||
      vapidPublicKey != null;

  @override
  String get providerSummary {
    final parts = <String>[];
    if (_hasFcm) parts.add('fcm');
    if (_hasApns) parts.add('apns');
    if (vapidPublicKey != null) parts.add('web_push');
    if (_hasWebhook) {
      parts.add(
        _webhookSenderVerified == false ? 'webhook_unreachable' : 'webhook',
      );
    }
    if (_customSender != null && parts.isEmpty) parts.add('custom_provider');
    return parts.isEmpty
        ? 'companion_poll_and_os_notifications'
        : parts.join('+');
  }

  /// Verifies that any configured `WATSAFE_PUSH_WEBHOOK_URL` actually has a
  /// reachable HTTP listener behind it instead of failing silently.
  @override
  Future<void> verifyConfiguredSenders() async {
    if (!_hasWebhook) {
      _webhookSenderVerified = null;
      return;
    }
    final uri = Uri.tryParse(_pushWebhookUrl);
    if (uri == null || !uri.hasAuthority) {
      _webhookSenderVerified = false;
      return;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.openUrl('HEAD', uri);
      final res = await req.close().timeout(const Duration(seconds: 3));
      await res.drain<void>();
      // Any non-5xx HTTP response proves a live HTTP service is listening.
      _webhookSenderVerified = res.statusCode > 0 && res.statusCode < 500;
    } catch (_) {
      _webhookSenderVerified = false;
    } finally {
      client.close(force: true);
    }
  }

  static bool _looksLikeWebBond(CompanionBondRecord bond) {
    final lowerPlat = bond.platform.toLowerCase();
    if (lowerPlat.contains('web') ||
        lowerPlat.contains('safari') ||
        lowerPlat.contains('chrome') ||
        lowerPlat.contains('home screen') ||
        lowerPlat.contains('browser')) {
      return true;
    }
    return bond.notificationChannel == 'web_push' ||
        bond.notificationChannel == 'needs_https' ||
        bond.notificationChannel == 'needs_home_screen' ||
        bond.notificationChannel == 'pending_permission' ||
        bond.notificationChannel == 'pending_setup' ||
        bond.notificationChannel == 'permission_denied';
  }

  @override
  Future<int> dispatchAlertToBonds({
    required List<CompanionBondRecord> bonds,
    required SessionAlertRecord alert,
    required String hostDisplayName,
    Future<void> Function(CompanionBondRecord expiredBond)?
    onBondSubscriptionExpired,
  }) async {
    final summary = await dispatchAlertWithSummary(
      bonds: bonds,
      alert: alert,
      hostDisplayName: hostDisplayName,
      onBondSubscriptionExpired: onBondSubscriptionExpired,
    );
    return summary.pushAcceptedCount;
  }

  @override
  Future<PushDispatchSummary> dispatchAlertWithSummary({
    required List<CompanionBondRecord> bonds,
    required SessionAlertRecord alert,
    required String hostDisplayName,
    Future<void> Function(CompanionBondRecord updatedBond)? onBondUpdated,
    Future<void> Function(CompanionBondRecord expiredBond)?
    onBondSubscriptionExpired,
  }) async {
    var activeCount = 0;
    var attemptedCount = 0;
    var acceptedCount = 0;
    var failedCount = 0;
    var webMissingPushCount = 0;
    final failureReasons = <String>[];

    // Lock-screen privacy invariant: ONLY device name and plain alarm message.
    // Coordinates are NEVER included in push notification payloads.
    final title = hostDisplayName.trim().isEmpty
        ? 'WATSafe Alert'
        : hostDisplayName.trim();
    final body = alert.isTest
        ? 'Test alert from $title — tap to open in Activity.'
        : 'Alarm triggered on $title — tap to view event.';
    final nowIso = DateTime.now().toUtc().toIso8601String();

    for (final bond in bonds) {
      if (bond.isRevoked) {
        continue;
      }
      activeCount += 1;

      final envelope = OutboundPushEnvelope(
        bondId: bond.bondId,
        deviceId: bond.deviceId,
        platform: bond.platform,
        notificationChannel: bond.notificationChannel,
        title: title,
        body: body,
        incidentId: alert.incidentId,
        pairingSessionId: alert.pairingSessionId,
        isTest: alert.isTest,
        pushToken: bond.pushToken,
        webPushEndpoint: bond.webPushEndpoint,
      );
      _sentEnvelopes.add(envelope);

      if (_customSender != null) {
        attemptedCount += 1;
        bond.lastPushAttemptAtUtcIso = nowIso;
        final ok = await _customSender(envelope);
        if (ok) {
          acceptedCount += 1;
          bond.lastPushAcceptedAtUtcIso = nowIso;
          bond.lastPushStatusCode = 201;
          bond.lastPushErrorCode = null;
        } else {
          failedCount += 1;
          bond.lastPushStatusCode = 502;
          bond.lastPushErrorCode = 'CUSTOM_SENDER_REJECTED';
          failureReasons.add('CUSTOM_SENDER_REJECTED');
        }
        if (onBondUpdated != null) {
          await onBondUpdated(bond);
        }
        continue;
      }

      if (!bond.notificationsEnabled) {
        if (_looksLikeWebBond(bond)) {
          webMissingPushCount += 1;
        }
        continue;
      }

      var attemptedThisBond = false;
      var sent = false;
      String? bondFailureReason;

      // 1. Direct RFC 8291 + RFC 8292 Web Push (iOS 16.4+ Home Screen PWA & Android Chrome)
      if (bond.hasValidWebPushSubscription) {
        attemptedThisBond = true;
        bond.lastPushAttemptAtUtcIso = nowIso;
        try {
          final subscription = WebPushSubscriptionData.validate(
            endpointRaw: bond.webPushEndpoint!,
            p256dhRaw: bond.webPushP256dh!,
            authRaw: bond.webPushAuth!,
          );
          final pushRes = await _webPushSender.sendJsonNotification(
            subscription: subscription,
            payload: <String, Object?>{
              'title': envelope.title,
              'body': envelope.body,
              'data': <String, Object?>{
                'incidentId': envelope.incidentId,
                'pairingSessionId': envelope.pairingSessionId,
                'isTest': envelope.isTest,
                'url':
                    '/companion?event=${Uri.encodeComponent(envelope.incidentId)}',
              },
            },
            incidentId: envelope.incidentId,
          );
          bond.lastPushStatusCode = pushRes.statusCode;
          if (pushRes.delivered) {
            sent = true;
            bond.lastPushAcceptedAtUtcIso = nowIso;
            bond.lastPushErrorCode = null;
          } else {
            bondFailureReason = pushRes.providerReason ?? 'PUSH_REJECTED';
            bond.lastPushErrorCode = bondFailureReason;
            if (pushRes.subscriptionExpired || pushRes.vapidMismatch) {
              bond.clearWebPushSubscription();
              if (onBondSubscriptionExpired != null) {
                await onBondSubscriptionExpired(bond);
              }
            }
          }
        } catch (err) {
          bondFailureReason = DirectWebPushSender.sanitizeDiagnosticText(
            '$err',
          );
          bond.lastPushStatusCode = 0;
          bond.lastPushErrorCode = bondFailureReason;
          sent = false;
        }
      } else if (_looksLikeWebBond(bond)) {
        webMissingPushCount += 1;
      }

      // 2. Native APNs / FCM push tokens (when native mobile companion apps register tokens)
      final token = bond.pushToken;
      final isIos = bond.platform.toLowerCase().contains('ios');
      if (!sent && token != null && token.isNotEmpty) {
        if (isIos && _hasApns) {
          attemptedThisBond = true;
          bond.lastPushAttemptAtUtcIso = nowIso;
          sent = await _sendApns(token: token, envelope: envelope);
          if (!sent) {
            bondFailureReason ??= 'APNS_REJECTED';
          }
        } else if (_hasFcm) {
          attemptedThisBond = true;
          bond.lastPushAttemptAtUtcIso = nowIso;
          sent = await _sendFcm(token: token, envelope: envelope);
          if (!sent) {
            bondFailureReason ??= 'FCM_REJECTED';
          }
        }
      }

      // 3. Verified external webhook gateway (only when configured & reachable)
      if (!sent && _hasVerifiedWebhook) {
        attemptedThisBond = true;
        bond.lastPushAttemptAtUtcIso = nowIso;
        sent = await _sendWebhook(envelope);
        if (!sent) {
          bondFailureReason ??= 'WEBHOOK_REJECTED';
        }
      }

      if (attemptedThisBond) {
        attemptedCount += 1;
        if (sent) {
          acceptedCount += 1;
          bond.lastPushAcceptedAtUtcIso = nowIso;
          bond.lastPushErrorCode = null;
        } else {
          failedCount += 1;
          final reason = bondFailureReason ?? 'PUSH_REJECTED';
          bond.lastPushErrorCode ??= reason;
          if (!failureReasons.contains(reason)) {
            failureReasons.add(reason);
          }
        }
        if (onBondUpdated != null) {
          await onBondUpdated(bond);
        }
      }
    }

    return PushDispatchSummary(
      activeBondCount: activeCount,
      pushAttemptedCount: attemptedCount,
      pushAcceptedCount: acceptedCount,
      pushFailedCount: failedCount,
      webBondsMissingPushCount: webMissingPushCount,
      failureReasons: List<String>.unmodifiable(failureReasons),
    );
  }

  Future<bool> _sendFcm({
    required String token,
    required OutboundPushEnvelope envelope,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      if (_fcmProjectId.isNotEmpty && _fcmBearerToken.isNotEmpty) {
        final uri = Uri.parse(
          'https://fcm.googleapis.com/v1/projects/$_fcmProjectId/messages:send',
        );
        final req = await client.postUrl(uri);
        req.headers.contentType = ContentType.json;
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $_fcmBearerToken',
        );
        req.write(
          jsonEncode(<String, Object?>{
            'message': <String, Object?>{
              'token': token,
              'notification': <String, Object?>{
                'title': envelope.title,
                'body': envelope.body,
              },
              'data': <String, String>{
                'incidentId': envelope.incidentId,
                'pairingSessionId': envelope.pairingSessionId,
                'isTest': '${envelope.isTest}',
              },
              'android': <String, Object?>{'priority': 'high'},
            },
          }),
        );
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode >= 200 && res.statusCode < 300;
      }

      if (_fcmServerKey.isNotEmpty) {
        final req = await client.postUrl(
          Uri.parse('https://fcm.googleapis.com/fcm/send'),
        );
        req.headers.contentType = ContentType.json;
        req.headers.set(HttpHeaders.authorizationHeader, 'key=$_fcmServerKey');
        req.write(
          jsonEncode(<String, Object?>{
            'to': token,
            'priority': 'high',
            'notification': <String, Object?>{
              'title': envelope.title,
              'body': envelope.body,
            },
            'data': <String, String>{
              'incidentId': envelope.incidentId,
              'pairingSessionId': envelope.pairingSessionId,
              'isTest': '${envelope.isTest}',
            },
          }),
        );
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode >= 200 && res.statusCode < 300;
      }
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
    return false;
  }

  Future<bool> _sendApns({
    required String token,
    required OutboundPushEnvelope envelope,
  }) async {
    final host = _apnsSandbox
        ? 'https://api.sandbox.push.apple.com'
        : 'https://api.push.apple.com';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.postUrl(Uri.parse('$host/3/device/$token'));
      req.headers.contentType = ContentType.json;
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'bearer $_apnsAuthToken',
      );
      req.headers.set('apns-topic', _apnsBundleId);
      req.headers.set('apns-push-type', 'alert');
      req.headers.set('apns-priority', '10');
      req.headers.set('apns-collapse-id', envelope.incidentId);
      req.write(
        jsonEncode(<String, Object?>{
          'aps': <String, Object?>{
            'alert': <String, Object?>{
              'title': envelope.title,
              'body': envelope.body,
            },
            'sound': 'default',
          },
          'incidentId': envelope.incidentId,
          'pairingSessionId': envelope.pairingSessionId,
          'isTest': envelope.isTest,
        }),
      );
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _sendWebhook(OutboundPushEnvelope envelope) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.postUrl(Uri.parse(_pushWebhookUrl));
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode(<String, Object?>{
          ...envelope.toSafeMetadataJson(),
          'pushToken': ?envelope.pushToken,
          'webPushEndpoint': ?envelope.webPushEndpoint,
        }),
      );
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
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
  Future<CompanionBondRecord?> findActiveBondByHandoffCode(
    String normalizedHandoffCode,
  );
  Future<List<CompanionBondRecord>> listActiveBondsForSession(
    String pairingSessionId,
  );
  Future<bool> revokeBond({
    required String pairingSessionId,
    required String deviceId,
  });
  Future<void> revokeSessionAndBonds(String pairingSessionId);

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
    AlertLocationData? location,
    String locationStatus = 'notRequested',
  });

  Future<SessionAlertRecord?> updateSessionAlertLocation({
    required String pairingSessionId,
    required String incidentId,
    AlertLocationData? location,
    required String locationStatus,
  });

  Future<SessionAlertRecord?> confirmSessionAlertReceipt({
    required String pairingSessionId,
    required String incidentId,
    required String confirmedAtUtc,
    required String receiptSource,
  });

  Future<SessionAlertRecord?> findAlertByIncidentId({
    required String pairingSessionId,
    required String incidentId,
  });

  Future<List<SessionAlertRecord>> listAlertsAfterSeq({
    required String pairingSessionId,
    required int afterSeq,
  });

  Future<int> latestAlertSeq(String pairingSessionId);

  Future<Map<String, String>?> loadPersistedVapidKeys() async => null;

  Future<void> savePersistedVapidKeys({
    required String publicKeyBase64Url,
    required String privateKeyBase64Url,
  }) async {}
}

/// Default zero-configuration in-memory store for isolated unit tests.
class InMemoryRelayStore implements RelayStore {
  InMemoryRelayStore({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, RelaySessionRecord> _sessionsById =
      <String, RelaySessionRecord>{};
  final Map<String, CompanionBondRecord> _bondsById =
      <String, CompanionBondRecord>{};
  final Map<String, List<SessionAlertRecord>> _alertsBySession =
      <String, List<SessionAlertRecord>>{};
  final Map<String, int> _seqBySession = <String, int>{};
  Map<String, String>? _vapidKeys;

  @override
  String get backendName => 'memory';

  @override
  String get redactedDescription => 'in-memory session store';

  @override
  Future<void> initialize() async {}

  @override
  Future<void> close() async {}

  @override
  Future<Map<String, String>?> loadPersistedVapidKeys() async => _vapidKeys;

  @override
  Future<void> savePersistedVapidKeys({
    required String publicKeyBase64Url,
    required String privateKeyBase64Url,
  }) async {
    _vapidKeys = <String, String>{
      'publicKey': publicKeyBase64Url,
      'privateKey': privateKeyBase64Url,
    };
  }

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
    final nowUtc = _clock().toUtc();
    for (final bond in _bondsById.values) {
      if (bond.matchesCompanionToken(companionToken, nowUtc)) {
        return bond;
      }
    }
    return null;
  }

  @override
  Future<CompanionBondRecord?> findActiveBondByHandoffCode(
    String normalizedHandoffCode,
  ) async {
    for (final bond in _bondsById.values) {
      if (!bond.isRevoked && bond.activeHandoffCode == normalizedHandoffCode) {
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
    final nowIso = _clock().toUtc().toIso8601String();
    for (final bond in _bondsById.values) {
      if (!bond.isRevoked &&
          bond.pairingSessionId == pairingSessionId &&
          bond.deviceId == deviceId) {
        bond.clearWebPushSubscription();
        bond.pushToken = null;
        bond.previousCompanionToken = null;
        bond.previousTokenGraceUntilUtc = null;
        bond.activeHandoffCode = null;
        bond.handoffExpiresAtUtc = null;
        bond.revokedAtUtcIso = nowIso;
        bond.connected = false;
        revokedAny = true;
      }
    }
    return revokedAny;
  }

  @override
  Future<void> revokeSessionAndBonds(String pairingSessionId) async {
    final nowIso = _clock().toUtc().toIso8601String();
    for (final bond in _bondsById.values) {
      if (!bond.isRevoked && bond.pairingSessionId == pairingSessionId) {
        bond.clearWebPushSubscription();
        bond.pushToken = null;
        bond.previousCompanionToken = null;
        bond.previousTokenGraceUntilUtc = null;
        bond.activeHandoffCode = null;
        bond.handoffExpiresAtUtc = null;
        bond.revokedAtUtcIso = nowIso;
        bond.connected = false;
      }
    }
    _alertsBySession.remove(pairingSessionId);
    _seqBySession.remove(pairingSessionId);
    _sessionsById.remove(pairingSessionId);
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
    AlertLocationData? location,
    String locationStatus = 'notRequested',
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
      updatedSeq: nextSeq,
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
      location: location,
      locationStatus: locationStatus,
    );
    list.add(created);
    return (alert: created, deduplicated: false);
  }

  @override
  Future<SessionAlertRecord?> updateSessionAlertLocation({
    required String pairingSessionId,
    required String incidentId,
    AlertLocationData? location,
    required String locationStatus,
  }) async {
    final list = _alertsBySession[pairingSessionId];
    if (list == null) {
      return null;
    }
    final idx = list.indexWhere((a) => a.incidentId == incidentId);
    if (idx < 0) {
      return null;
    }
    final nextSeq = (_seqBySession[pairingSessionId] ?? 0) + 1;
    _seqBySession[pairingSessionId] = nextSeq;
    final updated = list[idx].copyWith(
      updatedSeq: nextSeq,
      location: location,
      locationStatus: locationStatus,
    );
    list[idx] = updated;
    return updated;
  }

  @override
  Future<SessionAlertRecord?> confirmSessionAlertReceipt({
    required String pairingSessionId,
    required String incidentId,
    required String confirmedAtUtc,
    required String receiptSource,
  }) async {
    final list = _alertsBySession[pairingSessionId];
    if (list == null) {
      return null;
    }
    final idx = list.indexWhere((a) => a.incidentId == incidentId);
    if (idx < 0) {
      return null;
    }
    final current = list[idx];
    if (current.isReceiptConfirmed && current.receiptSource == 'push_sw') {
      return current;
    }
    final nextSeq = (_seqBySession[pairingSessionId] ?? 0) + 1;
    _seqBySession[pairingSessionId] = nextSeq;
    final updated = current.copyWith(
      updatedSeq: nextSeq,
      receiptConfirmedAtUtc: current.receiptConfirmedAtUtc ?? confirmedAtUtc,
      receiptSource: receiptSource,
    );
    list[idx] = updated;
    return updated;
  }

  @override
  Future<SessionAlertRecord?> findAlertByIncidentId({
    required String pairingSessionId,
    required String incidentId,
  }) async {
    final list = _alertsBySession[pairingSessionId];
    if (list == null) {
      return null;
    }
    for (final item in list) {
      if (item.incidentId == incidentId) {
        return item;
      }
    }
    return null;
  }

  @override
  Future<List<SessionAlertRecord>> listAlertsAfterSeq({
    required String pairingSessionId,
    required int afterSeq,
  }) async {
    final list =
        _alertsBySession[pairingSessionId] ?? const <SessionAlertRecord>[];
    return list.where((a) => a.effectiveSeq > afterSeq).toList(growable: false);
  }

  @override
  Future<int> latestAlertSeq(String pairingSessionId) async {
    return _seqBySession[pairingSessionId] ?? 0;
  }
}

/// Durable atomic JSON file store (`relay_store.json` + `vapid_keys.json` with
/// `0600` POSIX permissions) so pairing sessions, companion bonds, Web Push
/// subscriptions, VAPID keys, and incident alerts survive backend restarts and
/// updates even when PostgreSQL is not configured.
class FileRelayStore implements RelayStore {
  FileRelayStore({required this._directory, DateTime Function()? clock})
    : _inner = InMemoryRelayStore(clock: clock);

  factory FileRelayStore.fromEnvironment([
    Map<String, String>? environment,
    DateTime Function()? clock,
  ]) {
    final env = environment ?? Platform.environment;
    final explicit = (env['WATSAFE_DATA_DIR'] ?? '').trim();
    Directory dir;
    if (explicit.isNotEmpty) {
      dir = Directory(explicit);
    } else {
      final home = (env['HOME'] ?? env['USERPROFILE'] ?? env['APPDATA'] ?? '')
          .trim();
      if (home.isNotEmpty) {
        dir = Directory(
          '$home${Platform.pathSeparator}.watsafe${Platform.pathSeparator}relay',
        );
      } else {
        dir = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}watsafe_relay',
        );
      }
    }
    return FileRelayStore(directory: dir, clock: clock);
  }

  static const int _maxAlertsPerSession = 200;

  final Directory _directory;
  final InMemoryRelayStore _inner;
  Future<void> _writeChain = Future<void>.value();
  bool _initialized = false;

  File get _storeFile =>
      File('${_directory.path}${Platform.pathSeparator}relay_store.json');
  File get _vapidFile =>
      File('${_directory.path}${Platform.pathSeparator}vapid_keys.json');

  @override
  String get backendName => 'durable_file';

  @override
  String get redactedDescription => 'durable local file store';

  Future<void> _tightenFilePermissions(File file) async {
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', <String>['600', file.path]);
      } catch (_) {}
    }
  }

  @override
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await _directory.create(recursive: true);
    if (!await _storeFile.exists()) {
      return;
    }
    try {
      final raw = await _storeFile.readAsString();
      if (raw.trim().isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }
      final root = Map<String, Object?>.from(decoded);
      final sessionsRaw =
          root['sessions'] as List<Object?>? ?? const <Object?>[];
      for (final item in sessionsRaw.whereType<Map<Object?, Object?>>()) {
        final record = RelaySessionRecord.fromStorageJson(
          Map<String, Object?>.from(item),
        );
        if (record.pairingSessionId.isNotEmpty && record.hostToken.isNotEmpty) {
          _inner._sessionsById[record.pairingSessionId] = record;
        }
      }
      final bondsRaw = root['bonds'] as List<Object?>? ?? const <Object?>[];
      for (final item in bondsRaw.whereType<Map<Object?, Object?>>()) {
        final bond = CompanionBondRecord.fromStorageJson(
          Map<String, Object?>.from(item),
        );
        if (bond.bondId.isNotEmpty) {
          _inner._bondsById[bond.bondId] = bond;
        }
      }
      final seqRaw = root['seqBySession'];
      if (seqRaw is Map) {
        for (final entry in seqRaw.entries) {
          final v = entry.value;
          if (v is num) {
            _inner._seqBySession['${entry.key}'] = v.toInt();
          }
        }
      }
      final alertsRaw = root['alertsBySession'];
      if (alertsRaw is Map) {
        for (final entry in alertsRaw.entries) {
          final sessionId = '${entry.key}';
          final listRaw = entry.value;
          if (listRaw is List) {
            final parsed = listRaw
                .whereType<Map<Object?, Object?>>()
                .map(
                  (m) =>
                      SessionAlertRecord.fromJson(Map<String, Object?>.from(m)),
                )
                .toList();
            _inner._alertsBySession[sessionId] = parsed;
            for (final a in parsed) {
              final cur = _inner._seqBySession[sessionId] ?? 0;
              if (a.effectiveSeq > cur) {
                _inner._seqBySession[sessionId] = a.effectiveSeq;
              }
            }
          }
        }
      }
    } catch (_) {
      // Keep clean state if file is unreadable
    }
  }

  Future<void> _flushSnapshot() {
    final next = _writeChain
        .then((_) async {
          await _directory.create(recursive: true);
          final alertsJson = <String, Object?>{};
          for (final entry in _inner._alertsBySession.entries) {
            final items = entry.value;
            final trimmed = items.length > _maxAlertsPerSession
                ? items.sublist(items.length - _maxAlertsPerSession)
                : items;
            alertsJson[entry.key] = trimmed
                .map((a) => a.toJson())
                .toList(growable: false);
          }
          final payload = <String, Object?>{
            'schemaVersion': 1,
            'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
            'sessions': _inner._sessionsById.values
                .map((s) => s.toStorageJson())
                .toList(growable: false),
            'bonds': _inner._bondsById.values
                .map((b) => b.toStorageJson())
                .toList(growable: false),
            'seqBySession': _inner._seqBySession,
            'alertsBySession': alertsJson,
          };
          final encoded = const JsonEncoder.withIndent('  ').convert(payload);
          final tmp = File('${_storeFile.path}.tmp');
          await tmp.writeAsString(encoded, flush: true);
          await _tightenFilePermissions(tmp);
          await tmp.rename(_storeFile.path);
          await _tightenFilePermissions(_storeFile);
        })
        .catchError((_) {});
    _writeChain = next;
    return next;
  }

  @override
  Future<void> close() async {
    await _writeChain;
  }

  @override
  Future<Map<String, String>?> loadPersistedVapidKeys() async {
    await initialize();
    if (!await _vapidFile.exists()) {
      final legacy = File('.watsafe-runtime/vapid_keys.json');
      if (await legacy.exists()) {
        try {
          final legacyDecoded = jsonDecode(await legacy.readAsString());
          if (legacyDecoded is Map &&
              legacyDecoded['privateKey'] is String &&
              legacyDecoded['publicKey'] is String) {
            final migrated = <String, String>{
              'publicKey': legacyDecoded['publicKey'] as String,
              'privateKey': legacyDecoded['privateKey'] as String,
            };
            await savePersistedVapidKeys(
              publicKeyBase64Url: migrated['publicKey']!,
              privateKeyBase64Url: migrated['privateKey']!,
            );
            return migrated;
          }
        } catch (_) {}
      }
      return null;
    }
    try {
      final decoded = jsonDecode(await _vapidFile.readAsString());
      if (decoded is Map &&
          decoded['privateKey'] is String &&
          decoded['publicKey'] is String) {
        return <String, String>{
          'publicKey': decoded['publicKey'] as String,
          'privateKey': decoded['privateKey'] as String,
        };
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> savePersistedVapidKeys({
    required String publicKeyBase64Url,
    required String privateKeyBase64Url,
  }) async {
    await _directory.create(recursive: true);
    final tmp = File('${_vapidFile.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, String>{
        'publicKey': publicKeyBase64Url,
        'privateKey': privateKeyBase64Url,
        'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    await _tightenFilePermissions(tmp);
    await tmp.rename(_vapidFile.path);
    await _tightenFilePermissions(_vapidFile);
  }

  @override
  Future<void> saveSession(RelaySessionRecord session) async {
    await initialize();
    await _inner.saveSession(session);
    await _flushSnapshot();
  }

  @override
  Future<RelaySessionRecord?> findSessionById(String pairingSessionId) async {
    await initialize();
    return _inner.findSessionById(pairingSessionId);
  }

  @override
  Future<RelaySessionRecord?> findSessionByHostToken(String hostToken) async {
    await initialize();
    return _inner.findSessionByHostToken(hostToken);
  }

  @override
  Future<RelaySessionRecord?> findSessionByPairingCode(
    String normalizedCode,
  ) async {
    await initialize();
    return _inner.findSessionByPairingCode(normalizedCode);
  }

  @override
  Future<void> saveCompanionBond(CompanionBondRecord bond) async {
    await initialize();
    await _inner.saveCompanionBond(bond);
    await _flushSnapshot();
  }

  @override
  Future<CompanionBondRecord?> findActiveBondByCompanionToken(
    String companionToken,
  ) async {
    await initialize();
    return _inner.findActiveBondByCompanionToken(companionToken);
  }

  @override
  Future<CompanionBondRecord?> findActiveBondByHandoffCode(
    String normalizedHandoffCode,
  ) async {
    await initialize();
    return _inner.findActiveBondByHandoffCode(normalizedHandoffCode);
  }

  @override
  Future<List<CompanionBondRecord>> listActiveBondsForSession(
    String pairingSessionId,
  ) async {
    await initialize();
    return _inner.listActiveBondsForSession(pairingSessionId);
  }

  @override
  Future<bool> revokeBond({
    required String pairingSessionId,
    required String deviceId,
  }) async {
    await initialize();
    final revoked = await _inner.revokeBond(
      pairingSessionId: pairingSessionId,
      deviceId: deviceId,
    );
    if (revoked) {
      await _flushSnapshot();
    }
    return revoked;
  }

  @override
  Future<void> revokeSessionAndBonds(String pairingSessionId) async {
    await initialize();
    await _inner.revokeSessionAndBonds(pairingSessionId);
    await _flushSnapshot();
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
    AlertLocationData? location,
    String locationStatus = 'notRequested',
  }) async {
    await initialize();
    final result = await _inner.recordSessionAlert(
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
      location: location,
      locationStatus: locationStatus,
    );
    if (!result.deduplicated) {
      await _flushSnapshot();
    }
    return result;
  }

  @override
  Future<SessionAlertRecord?> updateSessionAlertLocation({
    required String pairingSessionId,
    required String incidentId,
    AlertLocationData? location,
    required String locationStatus,
  }) async {
    await initialize();
    final updated = await _inner.updateSessionAlertLocation(
      pairingSessionId: pairingSessionId,
      incidentId: incidentId,
      location: location,
      locationStatus: locationStatus,
    );
    if (updated != null) {
      await _flushSnapshot();
    }
    return updated;
  }

  @override
  Future<SessionAlertRecord?> confirmSessionAlertReceipt({
    required String pairingSessionId,
    required String incidentId,
    required String confirmedAtUtc,
    required String receiptSource,
  }) async {
    await initialize();
    final updated = await _inner.confirmSessionAlertReceipt(
      pairingSessionId: pairingSessionId,
      incidentId: incidentId,
      confirmedAtUtc: confirmedAtUtc,
      receiptSource: receiptSource,
    );
    if (updated != null) {
      await _flushSnapshot();
    }
    return updated;
  }

  @override
  Future<SessionAlertRecord?> findAlertByIncidentId({
    required String pairingSessionId,
    required String incidentId,
  }) async {
    await initialize();
    return _inner.findAlertByIncidentId(
      pairingSessionId: pairingSessionId,
      incidentId: incidentId,
    );
  }

  @override
  Future<List<SessionAlertRecord>> listAlertsAfterSeq({
    required String pairingSessionId,
    required int afterSeq,
  }) async {
    await initialize();
    return _inner.listAlertsAfterSeq(
      pairingSessionId: pairingSessionId,
      afterSeq: afterSeq,
    );
  }

  @override
  Future<int> latestAlertSeq(String pairingSessionId) async {
    await initialize();
    return _inner.latestAlertSeq(pairingSessionId);
  }
}

/// Environment-configured PostgreSQL / Aiven store.
///
/// Credentials are read exclusively from backend environment variables
/// (`AIVEN_DATABASE_URL` or `DATABASE_URL`, plus optional `AIVEN_CA_CERT_PATH`
/// or `PGSSLROOTCERT`) and are never exposed to clients or logs.
class PostgresRelayStore implements RelayStore {
  PostgresRelayStore._({
    required this._endpoint,
    required this._settings,
    required this._redactedSummary,
    required String tablePrefix,
  }) : _tablePrefix = _sanitizePrefix(tablePrefix);

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

    final caCertPem = (env['AIVEN_CA_CERT'] ?? '').trim();
    final caCertPath = (env['AIVEN_CA_CERT_PATH'] ?? env['PGSSLROOTCERT'] ?? '')
        .trim();
    final sslModeParam = (uri.queryParameters['sslmode'] ?? '')
        .trim()
        .toLowerCase();

    SecurityContext? securityContext;
    SslMode sslMode;
    if (caCertPem.isNotEmpty) {
      securityContext = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificatesBytes(utf8.encode(caCertPem));
      sslMode = SslMode.verifyFull;
    } else if (caCertPath.isNotEmpty) {
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
      connectTimeout: const Duration(seconds: 20),
      queryTimeout: const Duration(seconds: 20),
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
  Timer? _idleDisconnectTimer;

  static const Duration _idleConnectionTtl = Duration(seconds: 60);

  // Write-through in-memory cache so steady-state presence heartbeats and idle
  // companion polls keep the HTTP container warm without preventing serverless
  // PostgreSQL (e.g. Neon) from scaling compute to zero when state is unchanged.
  final Map<String, RelaySessionRecord> _sessionCacheById =
      <String, RelaySessionRecord>{};
  final Map<String, String> _sessionIdByHostToken = <String, String>{};
  final Map<String, String> _sessionStructuralFingerprint = <String, String>{};
  final Map<String, CompanionBondRecord> _bondCacheById =
      <String, CompanionBondRecord>{};
  final Map<String, List<CompanionBondRecord>> _bondsCacheBySessionId =
      <String, List<CompanionBondRecord>>{};
  final Map<String, String> _bondStructuralFingerprint = <String, String>{};
  final Map<String, int> _latestSeqCacheBySessionId = <String, int>{};

  static String _sessionSignature(RelaySessionRecord s) {
    return jsonEncode(<Object?>[
      s.pairingSessionId,
      s.hostDisplayName,
      s.hostToken,
      s.hostDeviceId,
      s.activePairingCode,
      s.codeExpiresAtUtc?.toIso8601String(),
      s.failedCodeAttempts,
      s.hostDisconnectedAtUtc?.toIso8601String(),
      s.hostProtectionState,
    ]);
  }

  static String _bondSignature(CompanionBondRecord b) {
    return jsonEncode(<Object?>[
      b.bondId,
      b.pairingSessionId,
      b.deviceId,
      b.displayName,
      b.platform,
      b.companionToken,
      b.previousCompanionToken,
      b.previousTokenGraceUntilUtc?.toIso8601String(),
      b.tokenRefreshedAtUtcIso,
      b.pairedAtUtcIso,
      b.connected,
      b.pushChannelReady,
      b.notificationsEnabled,
      b.notificationChannel,
      b.httpsReady,
      b.homeScreenInstalled,
      b.notificationPermission,
      b.pushSubscribed,
      b.backendPushRegistered,
      b.pushToken,
      b.webPushEndpoint,
      b.webPushP256dh,
      b.webPushAuth,
      b.subscribedVapidPublicKey,
      b.lastPushAttemptAtUtcIso,
      b.lastPushAcceptedAtUtcIso,
      b.lastPushStatusCode,
      b.lastPushErrorCode,
      b.lastReceiptAtUtcIso,
      b.lastReceiptIncidentId,
      b.lastReceiptSource,
      b.activeHandoffCode,
      b.handoffExpiresAtUtc?.toIso8601String(),
      b.revokedAtUtcIso,
    ]);
  }

  void _cacheLoadedSession(RelaySessionRecord s) {
    _sessionCacheById[s.pairingSessionId] = s;
    _sessionIdByHostToken[s.hostToken] = s.pairingSessionId;
    _sessionStructuralFingerprint[s.pairingSessionId] = _sessionSignature(s);
  }

  void _cacheLoadedBond(CompanionBondRecord b) {
    _bondCacheById[b.bondId] = b;
    _bondStructuralFingerprint[b.bondId] = _bondSignature(b);
    final list = _bondsCacheBySessionId[b.pairingSessionId];
    if (list != null) {
      final idx = list.indexWhere((item) => item.bondId == b.bondId);
      if (b.isRevoked) {
        if (idx >= 0) {
          list.removeAt(idx);
        }
      } else if (idx >= 0) {
        list[idx] = b;
      } else {
        list.add(b);
      }
    }
  }

  void _scheduleIdleDisconnect() {
    _idleDisconnectTimer?.cancel();
    _idleDisconnectTimer = Timer(_idleConnectionTtl, () {
      unawaited(_closeConnectionOnly());
    });
  }

  Future<void> _closeConnectionOnly() async {
    _idleDisconnectTimer?.cancel();
    _idleDisconnectTimer = null;
    final conn = _connection;
    _connection = null;
    if (conn != null && conn.isOpen) {
      try {
        await conn.close();
      } catch (_) {}
    }
  }

  String get _sessionsTable => '${_tablePrefix}pairing_sessions';
  String get _bondsTable => '${_tablePrefix}companion_bonds';
  String get _alertsTable => '${_tablePrefix}session_alerts';
  String get _secretsTable => '${_tablePrefix}server_secrets';

  @override
  String get backendName => 'aiven_postgres';

  @override
  String get redactedDescription => _redactedSummary;

  Future<Connection> _conn() async {
    _idleDisconnectTimer?.cancel();
    final existing = _connection;
    if (existing != null && existing.isOpen) {
      return existing;
    }
    final opened = await Connection.open(_endpoint, settings: _settings);
    _connection = opened;
    return opened;
  }

  Future<T> _withConn<T>(Future<T> Function(Connection conn) action) async {
    final first = await _conn();
    try {
      final result = await action(first);
      _scheduleIdleDisconnect();
      return result;
    } on SocketException {
      await _closeConnectionOnly();
    } on ServerException catch (e) {
      // Postgres 57P01..57P03 / 08xxx indicate terminated or dropped connection.
      final code = e.code ?? '';
      if (!code.startsWith('57P') && !code.startsWith('08')) {
        _scheduleIdleDisconnect();
        rethrow;
      }
      await _closeConnectionOnly();
    } on PgException {
      if (first.isOpen) {
        _scheduleIdleDisconnect();
        rethrow;
      }
      await _closeConnectionOnly();
    }
    final reopened = await _conn();
    try {
      return await action(reopened);
    } finally {
      _scheduleIdleDisconnect();
    }
  }

  Future<Result> _exec(Object query, {Object? parameters}) =>
      _withConn((conn) => conn.execute(query, parameters: parameters));

  @override
  Future<void> initialize() async {
    await _exec('''
      CREATE TABLE IF NOT EXISTS $_secretsTable (
        secret_key TEXT PRIMARY KEY,
        secret_value_json TEXT NOT NULL,
        updated_at_utc TIMESTAMPTZ NOT NULL
      )
    ''');

    await _exec('''
      CREATE TABLE IF NOT EXISTS $_sessionsTable (
        pairing_session_id TEXT PRIMARY KEY,
        host_display_name TEXT NOT NULL,
        host_token TEXT NOT NULL UNIQUE,
        host_device_id TEXT,
        active_pairing_code TEXT,
        code_expires_at_utc TIMESTAMPTZ,
        failed_code_attempts INTEGER NOT NULL DEFAULT 0,
        host_last_seen_at_utc TIMESTAMPTZ,
        host_disconnected_at_utc TIMESTAMPTZ,
        host_protection_state TEXT NOT NULL DEFAULT 'off',
        created_at_utc TIMESTAMPTZ NOT NULL
      )
    ''');
    await _exec(
      'ALTER TABLE $_sessionsTable ADD COLUMN IF NOT EXISTS failed_code_attempts INTEGER NOT NULL DEFAULT 0',
    );
    await _exec(
      'ALTER TABLE $_sessionsTable ADD COLUMN IF NOT EXISTS host_device_id TEXT',
    );
    await _exec(
      'ALTER TABLE $_sessionsTable ADD COLUMN IF NOT EXISTS host_last_seen_at_utc TIMESTAMPTZ',
    );
    await _exec(
      'ALTER TABLE $_sessionsTable ADD COLUMN IF NOT EXISTS host_disconnected_at_utc TIMESTAMPTZ',
    );
    await _exec(
      "ALTER TABLE $_sessionsTable ADD COLUMN IF NOT EXISTS host_protection_state TEXT NOT NULL DEFAULT 'off'",
    );

    await _exec('''
      CREATE TABLE IF NOT EXISTS $_bondsTable (
        bond_id TEXT PRIMARY KEY,
        pairing_session_id TEXT NOT NULL REFERENCES $_sessionsTable(pairing_session_id) ON DELETE CASCADE,
        device_id TEXT NOT NULL,
        display_name TEXT NOT NULL,
        platform TEXT NOT NULL,
        companion_token TEXT NOT NULL UNIQUE,
        previous_companion_token TEXT,
        previous_token_grace_until_utc TIMESTAMPTZ,
        token_refreshed_at_utc_iso TEXT,
        paired_at_utc_iso TEXT NOT NULL,
        connected BOOLEAN NOT NULL DEFAULT TRUE,
        push_channel_ready BOOLEAN NOT NULL DEFAULT FALSE,
        notifications_enabled BOOLEAN NOT NULL DEFAULT FALSE,
        notification_channel TEXT NOT NULL DEFAULT 'foreground_only',
        https_ready BOOLEAN NOT NULL DEFAULT FALSE,
        home_screen_installed BOOLEAN NOT NULL DEFAULT FALSE,
        notification_permission TEXT NOT NULL DEFAULT 'default',
        push_subscribed BOOLEAN NOT NULL DEFAULT FALSE,
        backend_push_registered BOOLEAN NOT NULL DEFAULT FALSE,
        push_token TEXT,
        web_push_endpoint TEXT,
        web_push_p256dh TEXT,
        web_push_auth TEXT,
        active_handoff_code TEXT,
        handoff_expires_at_utc TIMESTAMPTZ,
        revoked_at_utc_iso TEXT,
        last_seen_at_utc_iso TEXT
      )
    ''');
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS previous_companion_token TEXT',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS previous_token_grace_until_utc TIMESTAMPTZ',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS token_refreshed_at_utc_iso TEXT',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS notifications_enabled BOOLEAN NOT NULL DEFAULT FALSE',
    );
    await _exec(
      "ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS notification_channel TEXT NOT NULL DEFAULT 'foreground_only'",
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS https_ready BOOLEAN NOT NULL DEFAULT FALSE',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS home_screen_installed BOOLEAN NOT NULL DEFAULT FALSE',
    );
    await _exec(
      "ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS notification_permission TEXT NOT NULL DEFAULT 'default'",
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS push_subscribed BOOLEAN NOT NULL DEFAULT FALSE',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS backend_push_registered BOOLEAN NOT NULL DEFAULT FALSE',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS push_token TEXT',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS web_push_endpoint TEXT',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS web_push_p256dh TEXT',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS web_push_auth TEXT',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS active_handoff_code TEXT',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS handoff_expires_at_utc TIMESTAMPTZ',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS subscribed_vapid_public_key TEXT',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS last_push_attempt_at_utc_iso TEXT',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS last_push_accepted_at_utc_iso TEXT',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS last_push_status_code INTEGER',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS last_push_error_code TEXT',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS last_receipt_at_utc_iso TEXT',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS last_receipt_incident_id TEXT',
    );
    await _exec(
      'ALTER TABLE $_bondsTable ADD COLUMN IF NOT EXISTS last_receipt_source TEXT',
    );

    await _exec('''
      CREATE TABLE IF NOT EXISTS $_alertsTable (
        pairing_session_id TEXT NOT NULL REFERENCES $_sessionsTable(pairing_session_id) ON DELETE CASCADE,
        alert_seq INTEGER NOT NULL,
        updated_seq INTEGER NOT NULL DEFAULT 0,
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
        location_json TEXT,
        location_status TEXT NOT NULL DEFAULT 'notRequested',
        receipt_confirmed_at_utc TEXT,
        receipt_source TEXT,
        PRIMARY KEY (pairing_session_id, alert_seq),
        UNIQUE (pairing_session_id, incident_id)
      )
    ''');
    await _exec(
      'ALTER TABLE $_alertsTable ADD COLUMN IF NOT EXISTS updated_seq INTEGER NOT NULL DEFAULT 0',
    );
    await _exec(
      'ALTER TABLE $_alertsTable ADD COLUMN IF NOT EXISTS location_json TEXT',
    );
    await _exec(
      "ALTER TABLE $_alertsTable ADD COLUMN IF NOT EXISTS location_status TEXT NOT NULL DEFAULT 'notRequested'",
    );
    await _exec(
      'ALTER TABLE $_alertsTable ADD COLUMN IF NOT EXISTS receipt_confirmed_at_utc TEXT',
    );
    await _exec(
      'ALTER TABLE $_alertsTable ADD COLUMN IF NOT EXISTS receipt_source TEXT',
    );
  }

  @override
  Future<void> close() async {
    await _closeConnectionOnly();
  }

  @override
  Future<Map<String, String>?> loadPersistedVapidKeys() async {
    final rows = await _exec(
      Sql.named(
        'SELECT secret_value_json FROM $_secretsTable WHERE secret_key = @key LIMIT 1',
      ),
      parameters: const <String, Object?>{'key': 'vapid_key_pair'},
    );
    if (rows.isEmpty) {
      return null;
    }
    final raw = rows.first.toColumnMap()['secret_value_json'] as String?;
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map &&
        decoded['privateKey'] is String &&
        decoded['publicKey'] is String) {
      return <String, String>{
        'publicKey': decoded['publicKey'] as String,
        'privateKey': decoded['privateKey'] as String,
      };
    }
    return null;
  }

  @override
  Future<void> savePersistedVapidKeys({
    required String publicKeyBase64Url,
    required String privateKeyBase64Url,
  }) async {
    await _exec(
      Sql.named('''
        INSERT INTO $_secretsTable (secret_key, secret_value_json, updated_at_utc)
        VALUES (@key, @val, @nowUtc)
        ON CONFLICT (secret_key) DO UPDATE SET
          secret_value_json = EXCLUDED.secret_value_json,
          updated_at_utc = EXCLUDED.updated_at_utc
      '''),
      parameters: <String, Object?>{
        'key': 'vapid_key_pair',
        'val': jsonEncode(<String, String>{
          'publicKey': publicKeyBase64Url,
          'privateKey': privateKeyBase64Url,
        }),
        'nowUtc': DateTime.now().toUtc(),
      },
    );
  }

  DateTime? _parseDbUtc(Object? raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw.toUtc();
    return DateTime.tryParse('$raw')?.toUtc();
  }

  RelaySessionRecord _rowToSession(Map<String, dynamic> map) {
    final createdRaw = map['created_at_utc'];
    return RelaySessionRecord(
      pairingSessionId: map['pairing_session_id'] as String,
      hostDisplayName: map['host_display_name'] as String,
      hostToken: map['host_token'] as String,
      createdAtUtc: createdRaw is DateTime
          ? createdRaw.toUtc()
          : DateTime.parse('$createdRaw').toUtc(),
      hostDeviceId: map['host_device_id'] as String?,
      activePairingCode: map['active_pairing_code'] as String?,
      codeExpiresAtUtc: _parseDbUtc(map['code_expires_at_utc']),
      failedCodeAttempts: (map['failed_code_attempts'] as num?)?.toInt() ?? 0,
      hostLastSeenAtUtc: _parseDbUtc(map['host_last_seen_at_utc']),
      hostDisconnectedAtUtc: _parseDbUtc(map['host_disconnected_at_utc']),
      hostProtectionState: map['host_protection_state'] as String? ?? 'off',
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
      previousCompanionToken: map['previous_companion_token'] as String?,
      previousTokenGraceUntilUtc: _parseDbUtc(
        map['previous_token_grace_until_utc'],
      ),
      tokenRefreshedAtUtcIso: map['token_refreshed_at_utc_iso'] as String?,
      pairedAtUtcIso: map['paired_at_utc_iso'] as String,
      connected: map['connected'] as bool? ?? true,
      pushChannelReady: map['push_channel_ready'] as bool? ?? false,
      notificationsEnabled: map['notifications_enabled'] as bool? ?? false,
      notificationChannel:
          map['notification_channel'] as String? ?? 'foreground_only',
      httpsReady: map['https_ready'] as bool? ?? false,
      homeScreenInstalled: map['home_screen_installed'] as bool? ?? false,
      notificationPermission:
          map['notification_permission'] as String? ?? 'default',
      pushSubscribed: map['push_subscribed'] as bool? ?? false,
      backendPushRegistered: map['backend_push_registered'] as bool? ?? false,
      pushToken: map['push_token'] as String?,
      webPushEndpoint: map['web_push_endpoint'] as String?,
      webPushP256dh: map['web_push_p256dh'] as String?,
      webPushAuth: map['web_push_auth'] as String?,
      subscribedVapidPublicKey: map['subscribed_vapid_public_key'] as String?,
      lastPushAttemptAtUtcIso: map['last_push_attempt_at_utc_iso'] as String?,
      lastPushAcceptedAtUtcIso: map['last_push_accepted_at_utc_iso'] as String?,
      lastPushStatusCode: (map['last_push_status_code'] as num?)?.toInt(),
      lastPushErrorCode: map['last_push_error_code'] as String?,
      lastReceiptAtUtcIso: map['last_receipt_at_utc_iso'] as String?,
      lastReceiptIncidentId: map['last_receipt_incident_id'] as String?,
      lastReceiptSource: map['last_receipt_source'] as String?,
      activeHandoffCode: map['active_handoff_code'] as String?,
      handoffExpiresAtUtc: _parseDbUtc(map['handoff_expires_at_utc']),
      revokedAtUtcIso: map['revoked_at_utc_iso'] as String?,
      lastSeenAtUtcIso: map['last_seen_at_utc_iso'] as String?,
    );
  }

  SessionAlertRecord _rowToAlert(Map<String, dynamic> map) {
    AlertLocationData? loc;
    final locRaw = map['location_json'] as String?;
    if (locRaw != null && locRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(locRaw);
        if (decoded is Map) {
          loc = AlertLocationData.fromJson(Map<String, Object?>.from(decoded));
        }
      } catch (_) {}
    }
    final alertSeq = (map['alert_seq'] as num).toInt();
    final updatedRaw = (map['updated_seq'] as num?)?.toInt() ?? 0;
    return SessionAlertRecord(
      alertSeq: alertSeq,
      updatedSeq: updatedRaw > 0 ? updatedRaw : alertSeq,
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
      location: loc,
      locationStatus: map['location_status'] as String? ?? 'notRequested',
      receiptConfirmedAtUtc: map['receipt_confirmed_at_utc'] as String?,
      receiptSource: map['receipt_source'] as String?,
    );
  }

  @override
  Future<void> saveSession(RelaySessionRecord session) async {
    _sessionCacheById[session.pairingSessionId] = session;
    _sessionIdByHostToken[session.hostToken] = session.pairingSessionId;
    final nextFp = _sessionSignature(session);
    if (_sessionStructuralFingerprint[session.pairingSessionId] == nextFp) {
      return;
    }
    await _exec(
      Sql.named('''
        INSERT INTO $_sessionsTable (
          pairing_session_id,
          host_display_name,
          host_token,
          host_device_id,
          active_pairing_code,
          code_expires_at_utc,
          failed_code_attempts,
          host_last_seen_at_utc,
          host_disconnected_at_utc,
          host_protection_state,
          created_at_utc
        ) VALUES (
          @id,
          @name,
          @token,
          @hostDeviceId,
          @code,
          @expires,
          @failedAttempts,
          @hostLastSeen,
          @hostDisconnected,
          @hostProtectionState,
          @created
        )
        ON CONFLICT (pairing_session_id) DO UPDATE SET
          host_display_name = EXCLUDED.host_display_name,
          host_device_id = EXCLUDED.host_device_id,
          active_pairing_code = EXCLUDED.active_pairing_code,
          code_expires_at_utc = EXCLUDED.code_expires_at_utc,
          failed_code_attempts = EXCLUDED.failed_code_attempts,
          host_last_seen_at_utc = EXCLUDED.host_last_seen_at_utc,
          host_disconnected_at_utc = EXCLUDED.host_disconnected_at_utc,
          host_protection_state = EXCLUDED.host_protection_state
      '''),
      parameters: <String, Object?>{
        'id': session.pairingSessionId,
        'name': session.hostDisplayName,
        'token': session.hostToken,
        'hostDeviceId': session.hostDeviceId,
        'code': session.activePairingCode,
        'expires': session.codeExpiresAtUtc,
        'failedAttempts': session.failedCodeAttempts,
        'hostLastSeen': session.hostLastSeenAtUtc,
        'hostDisconnected': session.hostDisconnectedAtUtc,
        'hostProtectionState': session.hostProtectionState,
        'created': session.createdAtUtc,
      },
    );
    _sessionStructuralFingerprint[session.pairingSessionId] = nextFp;
  }

  @override
  Future<RelaySessionRecord?> findSessionById(String pairingSessionId) async {
    final cached = _sessionCacheById[pairingSessionId];
    if (cached != null) {
      return cached;
    }
    final rows = await _exec(
      Sql.named(
        'SELECT * FROM $_sessionsTable WHERE pairing_session_id = @id LIMIT 1',
      ),
      parameters: <String, Object?>{'id': pairingSessionId},
    );
    if (rows.isEmpty) {
      return null;
    }
    final loaded = _rowToSession(rows.first.toColumnMap());
    _cacheLoadedSession(loaded);
    return loaded;
  }

  @override
  Future<RelaySessionRecord?> findSessionByHostToken(String hostToken) async {
    final cachedId = _sessionIdByHostToken[hostToken];
    if (cachedId != null) {
      final cached = _sessionCacheById[cachedId];
      if (cached != null && cached.hostToken == hostToken) {
        return cached;
      }
    }
    final rows = await _exec(
      Sql.named(
        'SELECT * FROM $_sessionsTable WHERE host_token = @token LIMIT 1',
      ),
      parameters: <String, Object?>{'token': hostToken},
    );
    if (rows.isEmpty) {
      return null;
    }
    final loaded = _rowToSession(rows.first.toColumnMap());
    _cacheLoadedSession(loaded);
    return loaded;
  }

  @override
  Future<RelaySessionRecord?> findSessionByPairingCode(
    String normalizedCode,
  ) async {
    for (final s in _sessionCacheById.values) {
      if (s.activePairingCode == normalizedCode) {
        return s;
      }
    }
    final rows = await _exec(
      Sql.named(
        'SELECT * FROM $_sessionsTable WHERE active_pairing_code = @code LIMIT 1',
      ),
      parameters: <String, Object?>{'code': normalizedCode},
    );
    if (rows.isEmpty) {
      return null;
    }
    final loaded = _rowToSession(rows.first.toColumnMap());
    _cacheLoadedSession(loaded);
    return loaded;
  }

  @override
  Future<void> saveCompanionBond(CompanionBondRecord bond) async {
    _bondCacheById[bond.bondId] = bond;
    final cachedList = _bondsCacheBySessionId[bond.pairingSessionId];
    if (cachedList != null) {
      final idx = cachedList.indexWhere((b) => b.bondId == bond.bondId);
      if (bond.isRevoked) {
        if (idx >= 0) {
          cachedList.removeAt(idx);
        }
      } else if (idx >= 0) {
        cachedList[idx] = bond;
      } else {
        cachedList.add(bond);
      }
    }
    final nextFp = _bondSignature(bond);
    if (_bondStructuralFingerprint[bond.bondId] == nextFp) {
      return;
    }
    await _exec(
      Sql.named('''
        INSERT INTO $_bondsTable (
          bond_id,
          pairing_session_id,
          device_id,
          display_name,
          platform,
          companion_token,
          previous_companion_token,
          previous_token_grace_until_utc,
          token_refreshed_at_utc_iso,
          paired_at_utc_iso,
          connected,
          push_channel_ready,
          notifications_enabled,
          notification_channel,
          https_ready,
          home_screen_installed,
          notification_permission,
          push_subscribed,
          backend_push_registered,
          push_token,
          web_push_endpoint,
          web_push_p256dh,
          web_push_auth,
          subscribed_vapid_public_key,
          last_push_attempt_at_utc_iso,
          last_push_accepted_at_utc_iso,
          last_push_status_code,
          last_push_error_code,
          last_receipt_at_utc_iso,
          last_receipt_incident_id,
          last_receipt_source,
          active_handoff_code,
          handoff_expires_at_utc,
          revoked_at_utc_iso,
          last_seen_at_utc_iso
        ) VALUES (
          @bondId,
          @sessionId,
          @deviceId,
          @displayName,
          @platform,
          @companionToken,
          @previousCompanionToken,
          @previousTokenGraceUntilUtc,
          @tokenRefreshedAtUtcIso,
          @pairedAt,
          @connected,
          @pushReady,
          @notificationsEnabled,
          @notificationChannel,
          @httpsReady,
          @homeScreenInstalled,
          @notificationPermission,
          @pushSubscribed,
          @backendPushRegistered,
          @pushToken,
          @webPushEndpoint,
          @webPushP256dh,
          @webPushAuth,
          @subscribedVapidPublicKey,
          @lastPushAttemptAtUtcIso,
          @lastPushAcceptedAtUtcIso,
          @lastPushStatusCode,
          @lastPushErrorCode,
          @lastReceiptAtUtcIso,
          @lastReceiptIncidentId,
          @lastReceiptSource,
          @activeHandoffCode,
          @handoffExpiresAtUtc,
          @revokedAt,
          @lastSeen
        )
        ON CONFLICT (bond_id) DO UPDATE SET
          platform = EXCLUDED.platform,
          companion_token = EXCLUDED.companion_token,
          previous_companion_token = EXCLUDED.previous_companion_token,
          previous_token_grace_until_utc = EXCLUDED.previous_token_grace_until_utc,
          token_refreshed_at_utc_iso = EXCLUDED.token_refreshed_at_utc_iso,
          connected = EXCLUDED.connected,
          push_channel_ready = EXCLUDED.push_channel_ready,
          notifications_enabled = EXCLUDED.notifications_enabled,
          notification_channel = EXCLUDED.notification_channel,
          https_ready = EXCLUDED.https_ready,
          home_screen_installed = EXCLUDED.home_screen_installed,
          notification_permission = EXCLUDED.notification_permission,
          push_subscribed = EXCLUDED.push_subscribed,
          backend_push_registered = EXCLUDED.backend_push_registered,
          push_token = EXCLUDED.push_token,
          web_push_endpoint = EXCLUDED.web_push_endpoint,
          web_push_p256dh = EXCLUDED.web_push_p256dh,
          web_push_auth = EXCLUDED.web_push_auth,
          subscribed_vapid_public_key = EXCLUDED.subscribed_vapid_public_key,
          last_push_attempt_at_utc_iso = EXCLUDED.last_push_attempt_at_utc_iso,
          last_push_accepted_at_utc_iso = EXCLUDED.last_push_accepted_at_utc_iso,
          last_push_status_code = EXCLUDED.last_push_status_code,
          last_push_error_code = EXCLUDED.last_push_error_code,
          last_receipt_at_utc_iso = EXCLUDED.last_receipt_at_utc_iso,
          last_receipt_incident_id = EXCLUDED.last_receipt_incident_id,
          last_receipt_source = EXCLUDED.last_receipt_source,
          active_handoff_code = EXCLUDED.active_handoff_code,
          handoff_expires_at_utc = EXCLUDED.handoff_expires_at_utc,
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
        'previousCompanionToken': bond.previousCompanionToken,
        'previousTokenGraceUntilUtc': bond.previousTokenGraceUntilUtc,
        'tokenRefreshedAtUtcIso': bond.tokenRefreshedAtUtcIso,
        'pairedAt': bond.pairedAtUtcIso,
        'connected': bond.connected,
        'pushReady': bond.pushChannelReady,
        'notificationsEnabled': bond.notificationsEnabled,
        'notificationChannel': bond.notificationChannel,
        'httpsReady': bond.httpsReady,
        'homeScreenInstalled': bond.homeScreenInstalled,
        'notificationPermission': bond.notificationPermission,
        'pushSubscribed': bond.pushSubscribed,
        'backendPushRegistered': bond.backendPushRegistered,
        'pushToken': bond.pushToken,
        'webPushEndpoint': bond.webPushEndpoint,
        'webPushP256dh': bond.webPushP256dh,
        'webPushAuth': bond.webPushAuth,
        'subscribedVapidPublicKey': bond.subscribedVapidPublicKey,
        'lastPushAttemptAtUtcIso': bond.lastPushAttemptAtUtcIso,
        'lastPushAcceptedAtUtcIso': bond.lastPushAcceptedAtUtcIso,
        'lastPushStatusCode': bond.lastPushStatusCode,
        'lastPushErrorCode': bond.lastPushErrorCode,
        'lastReceiptAtUtcIso': bond.lastReceiptAtUtcIso,
        'lastReceiptIncidentId': bond.lastReceiptIncidentId,
        'lastReceiptSource': bond.lastReceiptSource,
        'activeHandoffCode': bond.activeHandoffCode,
        'handoffExpiresAtUtc': bond.handoffExpiresAtUtc,
        'revokedAt': bond.revokedAtUtcIso,
        'lastSeen': bond.lastSeenAtUtcIso,
      },
    );
    _bondStructuralFingerprint[bond.bondId] = nextFp;
  }

  @override
  Future<CompanionBondRecord?> findActiveBondByCompanionToken(
    String companionToken,
  ) async {
    final nowUtc = DateTime.now().toUtc();
    for (final cached in _bondCacheById.values) {
      if (cached.matchesCompanionToken(companionToken, nowUtc)) {
        return cached;
      }
    }
    final rows = await _exec(
      Sql.named('''
        SELECT * FROM $_bondsTable
        WHERE revoked_at_utc_iso IS NULL
          AND (
            companion_token = @token
            OR (
              previous_companion_token = @token
              AND previous_token_grace_until_utc IS NOT NULL
              AND previous_token_grace_until_utc > @nowUtc
            )
          )
        LIMIT 1
      '''),
      parameters: <String, Object?>{'token': companionToken, 'nowUtc': nowUtc},
    );
    if (rows.isEmpty) {
      return null;
    }
    final loaded = _rowToBond(rows.first.toColumnMap());
    _cacheLoadedBond(loaded);
    return loaded;
  }

  @override
  Future<CompanionBondRecord?> findActiveBondByHandoffCode(
    String normalizedHandoffCode,
  ) async {
    for (final cached in _bondCacheById.values) {
      if (!cached.isRevoked &&
          cached.activeHandoffCode == normalizedHandoffCode) {
        return cached;
      }
    }
    final rows = await _exec(
      Sql.named('''
        SELECT * FROM $_bondsTable
        WHERE active_handoff_code = @code AND revoked_at_utc_iso IS NULL
        LIMIT 1
      '''),
      parameters: <String, Object?>{'code': normalizedHandoffCode},
    );
    if (rows.isEmpty) {
      return null;
    }
    final loaded = _rowToBond(rows.first.toColumnMap());
    _cacheLoadedBond(loaded);
    return loaded;
  }

  @override
  Future<List<CompanionBondRecord>> listActiveBondsForSession(
    String pairingSessionId,
  ) async {
    final cached = _bondsCacheBySessionId[pairingSessionId];
    if (cached != null) {
      return cached
          .where((b) => !b.isRevoked && b.pairingSessionId == pairingSessionId)
          .toList(growable: false);
    }
    final rows = await _exec(
      Sql.named('''
        SELECT * FROM $_bondsTable
        WHERE pairing_session_id = @sessionId AND revoked_at_utc_iso IS NULL
        ORDER BY paired_at_utc_iso ASC
      '''),
      parameters: <String, Object?>{'sessionId': pairingSessionId},
    );
    final loaded = rows.map((r) => _rowToBond(r.toColumnMap())).toList();
    _bondsCacheBySessionId[pairingSessionId] = loaded;
    for (final bond in loaded) {
      _bondCacheById[bond.bondId] = bond;
      _bondStructuralFingerprint[bond.bondId] = _bondSignature(bond);
    }
    return List<CompanionBondRecord>.unmodifiable(loaded);
  }

  @override
  Future<bool> revokeBond({
    required String pairingSessionId,
    required String deviceId,
  }) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final res = await _exec(
      Sql.named('''
        UPDATE $_bondsTable
        SET revoked_at_utc_iso = @nowIso,
            connected = FALSE,
            notifications_enabled = FALSE,
            push_channel_ready = FALSE,
            push_subscribed = FALSE,
            backend_push_registered = FALSE,
            previous_companion_token = NULL,
            previous_token_grace_until_utc = NULL,
            push_token = NULL,
            web_push_endpoint = NULL,
            web_push_p256dh = NULL,
            web_push_auth = NULL,
            active_handoff_code = NULL,
            handoff_expires_at_utc = NULL
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
    final toRemoveIds = _bondCacheById.values
        .where(
          (b) =>
              b.pairingSessionId == pairingSessionId && b.deviceId == deviceId,
        )
        .map((b) => b.bondId)
        .toList(growable: false);
    for (final id in toRemoveIds) {
      _bondCacheById.remove(id);
      _bondStructuralFingerprint.remove(id);
    }
    _bondsCacheBySessionId[pairingSessionId]?.removeWhere(
      (b) => b.deviceId == deviceId,
    );
    return res.affectedRows > 0;
  }

  @override
  Future<void> revokeSessionAndBonds(String pairingSessionId) async {
    await _exec(
      Sql.named(
        'DELETE FROM $_sessionsTable WHERE pairing_session_id = @sessionId',
      ),
      parameters: <String, Object?>{'sessionId': pairingSessionId},
    );
    final removedSession = _sessionCacheById.remove(pairingSessionId);
    if (removedSession != null) {
      _sessionIdByHostToken.remove(removedSession.hostToken);
    }
    _sessionStructuralFingerprint.remove(pairingSessionId);
    _bondsCacheBySessionId.remove(pairingSessionId);
    _latestSeqCacheBySessionId.remove(pairingSessionId);
    final bondIds = _bondCacheById.values
        .where((b) => b.pairingSessionId == pairingSessionId)
        .map((b) => b.bondId)
        .toList(growable: false);
    for (final id in bondIds) {
      _bondCacheById.remove(id);
      _bondStructuralFingerprint.remove(id);
    }
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
    AlertLocationData? location,
    String locationStatus = 'notRequested',
  }) async {
    final result = await _withConn(
      (conn) => conn.runTx((tx) async {
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
          SELECT COALESCE(MAX(GREATEST(alert_seq, updated_seq)), 0) + 1 AS next_seq
          FROM $_alertsTable
          WHERE pairing_session_id = @sessionId
        '''),
          parameters: <String, Object?>{'sessionId': pairingSessionId},
        );
        final nextSeq =
            (seqRows.first.toColumnMap()['next_seq'] as num?)?.toInt() ?? 1;
        final locJson = location != null ? jsonEncode(location.toJson()) : null;

        await tx.execute(
          Sql.named('''
          INSERT INTO $_alertsTable (
            pairing_session_id,
            alert_seq,
            updated_seq,
            incident_id,
            session_id,
            kind,
            detector_type,
            triggered_at_utc,
            trigger_summary,
            created_at_utc,
            peak_motion_score,
            host_display_name,
            is_test,
            location_json,
            location_status
          ) VALUES (
            @pairingSessionId,
            @alertSeq,
            @updatedSeq,
            @incidentId,
            @sessionId,
            @kind,
            @detectorType,
            @triggeredAtUtc,
            @triggerSummary,
            @createdAtUtc,
            @peakMotionScore,
            @hostDisplayName,
            @isTest,
            @locationJson,
            @locationStatus
          )
        '''),
          parameters: <String, Object?>{
            'pairingSessionId': pairingSessionId,
            'alertSeq': nextSeq,
            'updatedSeq': nextSeq,
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
            'locationJson': locJson,
            'locationStatus': locationStatus,
          },
        );

        return (
          alert: SessionAlertRecord(
            alertSeq: nextSeq,
            updatedSeq: nextSeq,
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
            location: location,
            locationStatus: locationStatus,
          ),
          deduplicated: false,
        );
      }),
    );
    final prevSeq = _latestSeqCacheBySessionId[pairingSessionId] ?? 0;
    if (result.alert.effectiveSeq > prevSeq) {
      _latestSeqCacheBySessionId[pairingSessionId] = result.alert.effectiveSeq;
    }
    return result;
  }

  @override
  Future<SessionAlertRecord?> updateSessionAlertLocation({
    required String pairingSessionId,
    required String incidentId,
    AlertLocationData? location,
    required String locationStatus,
  }) async {
    final updated = await _withConn(
      (conn) => conn.runTx((tx) async {
        final seqRows = await tx.execute(
          Sql.named('''
          SELECT COALESCE(MAX(GREATEST(alert_seq, updated_seq)), 0) + 1 AS next_seq
          FROM $_alertsTable
          WHERE pairing_session_id = @sessionId
        '''),
          parameters: <String, Object?>{'sessionId': pairingSessionId},
        );
        final nextSeq =
            (seqRows.first.toColumnMap()['next_seq'] as num?)?.toInt() ?? 1;
        final locJson = location != null ? jsonEncode(location.toJson()) : null;

        final updatedRows = await tx.execute(
          Sql.named('''
          UPDATE $_alertsTable
          SET updated_seq = @updatedSeq,
              location_json = COALESCE(@locationJson, location_json),
              location_status = @locationStatus
          WHERE pairing_session_id = @sessionId AND incident_id = @incidentId
          RETURNING *
        '''),
          parameters: <String, Object?>{
            'updatedSeq': nextSeq,
            'locationJson': locJson,
            'locationStatus': locationStatus,
            'sessionId': pairingSessionId,
            'incidentId': incidentId,
          },
        );
        if (updatedRows.isEmpty) {
          return null;
        }
        return _rowToAlert(updatedRows.first.toColumnMap());
      }),
    );
    if (updated != null) {
      final prevSeq = _latestSeqCacheBySessionId[pairingSessionId] ?? 0;
      if (updated.effectiveSeq > prevSeq) {
        _latestSeqCacheBySessionId[pairingSessionId] = updated.effectiveSeq;
      }
    }
    return updated;
  }

  @override
  Future<SessionAlertRecord?> confirmSessionAlertReceipt({
    required String pairingSessionId,
    required String incidentId,
    required String confirmedAtUtc,
    required String receiptSource,
  }) async {
    final updated = await _withConn(
      (conn) => conn.runTx((tx) async {
        final existingRows = await tx.execute(
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
        if (existingRows.isEmpty) {
          return null;
        }
        final current = _rowToAlert(existingRows.first.toColumnMap());
        if (current.isReceiptConfirmed && current.receiptSource == 'push_sw') {
          return current;
        }
        final seqRows = await tx.execute(
          Sql.named('''
            SELECT COALESCE(MAX(GREATEST(alert_seq, updated_seq)), 0) + 1 AS next_seq
            FROM $_alertsTable
            WHERE pairing_session_id = @sessionId
          '''),
          parameters: <String, Object?>{'sessionId': pairingSessionId},
        );
        final nextSeq =
            (seqRows.first.toColumnMap()['next_seq'] as num?)?.toInt() ?? 1;
        final updatedRows = await tx.execute(
          Sql.named('''
            UPDATE $_alertsTable
            SET updated_seq = @updatedSeq,
                receipt_confirmed_at_utc = COALESCE(receipt_confirmed_at_utc, @confirmedAtUtc),
                receipt_source = @receiptSource
            WHERE pairing_session_id = @sessionId AND incident_id = @incidentId
            RETURNING *
          '''),
          parameters: <String, Object?>{
            'updatedSeq': nextSeq,
            'confirmedAtUtc': confirmedAtUtc,
            'receiptSource': receiptSource,
            'sessionId': pairingSessionId,
            'incidentId': incidentId,
          },
        );
        if (updatedRows.isEmpty) {
          return null;
        }
        return _rowToAlert(updatedRows.first.toColumnMap());
      }),
    );
    if (updated != null) {
      final prevSeq = _latestSeqCacheBySessionId[pairingSessionId] ?? 0;
      if (updated.effectiveSeq > prevSeq) {
        _latestSeqCacheBySessionId[pairingSessionId] = updated.effectiveSeq;
      }
    }
    return updated;
  }

  @override
  Future<SessionAlertRecord?> findAlertByIncidentId({
    required String pairingSessionId,
    required String incidentId,
  }) async {
    final rows = await _exec(
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
    if (rows.isEmpty) {
      return null;
    }
    return _rowToAlert(rows.first.toColumnMap());
  }

  @override
  Future<List<SessionAlertRecord>> listAlertsAfterSeq({
    required String pairingSessionId,
    required int afterSeq,
  }) async {
    final cachedMax = _latestSeqCacheBySessionId[pairingSessionId];
    if (cachedMax != null && afterSeq >= cachedMax) {
      return const <SessionAlertRecord>[];
    }
    final rows = await _exec(
      Sql.named('''
        SELECT * FROM $_alertsTable
        WHERE pairing_session_id = @sessionId
          AND GREATEST(alert_seq, updated_seq) > @afterSeq
        ORDER BY alert_seq ASC
      '''),
      parameters: <String, Object?>{
        'sessionId': pairingSessionId,
        'afterSeq': afterSeq,
      },
    );
    final list = rows
        .map((r) => _rowToAlert(r.toColumnMap()))
        .toList(growable: false);
    if (list.isEmpty && cachedMax == null) {
      _latestSeqCacheBySessionId[pairingSessionId] = afterSeq;
    } else {
      var maxSeen = cachedMax ?? 0;
      for (final item in list) {
        if (item.effectiveSeq > maxSeen) {
          maxSeen = item.effectiveSeq;
        }
      }
      _latestSeqCacheBySessionId[pairingSessionId] = maxSeen;
    }
    return list;
  }

  @override
  Future<int> latestAlertSeq(String pairingSessionId) async {
    final cached = _latestSeqCacheBySessionId[pairingSessionId];
    if (cached != null) {
      return cached;
    }
    final rows = await _exec(
      Sql.named('''
        SELECT COALESCE(MAX(GREATEST(alert_seq, updated_seq)), 0) AS max_seq
        FROM $_alertsTable
        WHERE pairing_session_id = @sessionId
      '''),
      parameters: <String, Object?>{'sessionId': pairingSessionId},
    );
    final seq = (rows.first.toColumnMap()['max_seq'] as num?)?.toInt() ?? 0;
    _latestSeqCacheBySessionId[pairingSessionId] = seq;
    return seq;
  }
}

class _FailedAttemptWindow {
  _FailedAttemptWindow({required this.firstFailedAtUtc, this.count = 0});
  DateTime firstFailedAtUtc;
  int count;
}

/// Standalone WATSafe REST Relay Server implementing session-scoped QR/code
/// pairing, browser companion web flow (`/pair`), failed-attempt rate limiting,
/// server-side push dispatch, authenticated location updates, strict privacy &
/// credential filtering, and optional Aiven PostgreSQL persistence.
class WatSafeRelayServer {
  WatSafeRelayServer({
    RelayStore? store,
    PushProviderAdapter? pushProvider,
    DateTime Function()? clock,
    this.pairingCodeTtl = const Duration(minutes: 5),
    this.handoffCodeTtl = const Duration(minutes: 10),
    this.hostOnlineTtl = const Duration(seconds: 45),
    this.tokenRefreshGraceWindow = const Duration(seconds: 60),
    this.maxFailedPairingAttempts = 5,
    this.failedAttemptWindow = const Duration(minutes: 10),
    Map<String, String>? environment,
  }) : _store = store ?? InMemoryRelayStore(clock: clock),
       _pushProvider =
           pushProvider ??
           EnvironmentPushProviderAdapter(environment: environment),
       _clock = clock ?? DateTime.now,
       _env = environment ?? Platform.environment;

  /// Creates a relay server backed by Aiven PostgreSQL when `AIVEN_DATABASE_URL`
  /// or `DATABASE_URL` is set in [environment], or falls back to durable
  /// [FileRelayStore] on disk so pairing records, push subscriptions, and VAPID
  /// keys survive restarts and deployments.
  factory WatSafeRelayServer.fromEnvironment({
    Map<String, String>? environment,
    PushProviderAdapter? pushProvider,
    DateTime Function()? clock,
    Duration pairingCodeTtl = const Duration(minutes: 5),
    Duration hostOnlineTtl = const Duration(seconds: 45),
  }) {
    final pgStore = PostgresRelayStore.fromEnvironment(environment);
    return WatSafeRelayServer(
      store: pgStore ?? FileRelayStore.fromEnvironment(environment, clock),
      pushProvider:
          pushProvider ??
          EnvironmentPushProviderAdapter(
            environment: environment,
            persistVapidKeysToDisk: true,
          ),
      clock: clock,
      pairingCodeTtl: pairingCodeTtl,
      hostOnlineTtl: hostOnlineTtl,
      environment: environment,
    );
  }

  static const String companionSwVersion = '2026.11.16-v3';
  static const String _codeAlphabet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

  final RelayStore _store;
  final PushProviderAdapter _pushProvider;
  final DateTime Function() _clock;
  final Map<String, String> _env;
  final Duration pairingCodeTtl;
  final Duration handoffCodeTtl;
  final Duration hostOnlineTtl;
  final Duration tokenRefreshGraceWindow;
  final int maxFailedPairingAttempts;
  final Duration failedAttemptWindow;
  final Random _random = Random.secure();

  HttpServer? _server;
  String? _dynamicPublicOrigin;
  int _seq = 0;

  final Map<String, _FailedAttemptWindow> _failedAttemptsByClient =
      <String, _FailedAttemptWindow>{};
  final List<Map<String, Object?>> _registeredDevices =
      <Map<String, Object?>>[];
  final List<Map<String, Object?>> _pairedDevicesSnapshot =
      <Map<String, Object?>>[];
  final Map<String, Map<String, Object?>> _reportedIncidentsSnapshot =
      <String, Map<String, Object?>>{};

  int get port => _server?.port ?? 0;
  String get storageBackend => _store.backendName;
  String get storageDescription => _store.redactedDescription;
  PushProviderAdapter get pushProvider => _pushProvider;
  String? get dynamicPublicOrigin => _dynamicPublicOrigin;

  bool get _isEphemeralCloudContainer {
    final isRender =
        (_env['RENDER'] ?? '').trim().toLowerCase() == 'true' ||
        (_env['RENDER_EXTERNAL_URL'] ?? '').trim().isNotEmpty;
    final isCloudRun = (_env['K_SERVICE'] ?? '').trim().isNotEmpty;
    final isHeroku = (_env['DYNO'] ?? '').trim().isNotEmpty;
    final isFly = (_env['FLY_APP_NAME'] ?? '').trim().isNotEmpty;
    final hasPersistentVolume =
        (_env['WATSAFE_PERSISTENT_VOLUME'] ?? '').trim().toLowerCase() ==
        'true';
    return (isRender || isCloudRun || isHeroku || isFly) &&
        !hasPersistentVolume;
  }

  /// True only when pairing sessions, Web Push subscriptions, and VAPID keys
  /// are backed by storage that survives restarts and cloud redeployments.
  bool get isStorageDurable {
    if (_store.backendName == 'aiven_postgres') {
      return true;
    }
    if (_store.backendName == 'durable_file') {
      return !_isEphemeralCloudContainer;
    }
    return false;
  }

  String? get storageDurabilityWarning {
    if (_store.backendName == 'memory') {
      return 'In-memory store does not persist across restarts.';
    }
    if (_store.backendName == 'durable_file' && _isEphemeralCloudContainer) {
      return 'Cloud container filesystem is ephemeral and resets on redeploy or spin-down. Configure AIVEN_DATABASE_URL in environment secrets for permanent pairing, push subscription, and VAPID key persistence.';
    }
    return null;
  }

  List<Map<String, Object?>> get pairedDevices =>
      List<Map<String, Object?>>.unmodifiable(_pairedDevicesSnapshot);
  List<Map<String, Object?>> get reportedIncidents =>
      List<Map<String, Object?>>.unmodifiable(
        _reportedIncidentsSnapshot.values,
      );

  static String normalizePairingCode(String raw) {
    return raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  static String formatDisplayPairingCode(String normalized) {
    if (normalized.length == 6) {
      return '${normalized.substring(0, 3)}-${normalized.substring(3)}';
    }
    return normalized;
  }

  Future<int> start({InternetAddress? address, int port = 8787}) async {
    await _store.initialize();
    final push = _pushProvider;
    if (push is EnvironmentPushProviderAdapter) {
      await push.syncDurableVapidKeys(_store);
    }
    await _pushProvider.verifyConfiguredSenders();
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

  String _clientRateLimitKey(HttpRequest request) {
    final forwarded = request.headers.value('x-forwarded-for');
    if (forwarded != null && forwarded.trim().isNotEmpty) {
      return forwarded.split(',').first.trim();
    }
    return request.connectionInfo?.remoteAddress.address ?? 'unknown_client';
  }

  bool _isClientRateLimited(String clientKey, DateTime nowUtc) {
    final entry = _failedAttemptsByClient[clientKey];
    if (entry == null) {
      return false;
    }
    if (nowUtc.difference(entry.firstFailedAtUtc) >= failedAttemptWindow) {
      _failedAttemptsByClient.remove(clientKey);
      return false;
    }
    return entry.count >= maxFailedPairingAttempts;
  }

  void _recordFailedPairingAttempt(String clientKey, DateTime nowUtc) {
    final existing = _failedAttemptsByClient[clientKey];
    if (existing == null ||
        nowUtc.difference(existing.firstFailedAtUtc) >= failedAttemptWindow) {
      _failedAttemptsByClient[clientKey] = _FailedAttemptWindow(
        firstFailedAtUtc: nowUtc,
        count: 1,
      );
    } else {
      existing.count += 1;
    }
  }

  void _clearFailedPairingAttempts(String clientKey) {
    _failedAttemptsByClient.remove(clientKey);
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

  static bool isEphemeralTunnelOrigin(String? rawOrigin) {
    if (rawOrigin == null || rawOrigin.trim().isEmpty) {
      return false;
    }
    final parsed = Uri.tryParse(rawOrigin.trim());
    final host = (parsed?.host ?? rawOrigin.trim()).toLowerCase();
    return host.endsWith('.trycloudflare.com') ||
        host.endsWith('.lhr.life') ||
        host.endsWith('.localhost.run') ||
        host.endsWith('.ngrok-free.app') ||
        host.endsWith('.ngrok-free.dev') ||
        host.endsWith('.ngrok.io');
  }

  String? _configuredPermanentHttpsOrigin() {
    final candidates = <String>[
      (_env['WATSAFE_PUBLIC_URL'] ?? '').trim(),
      (_env['RENDER_EXTERNAL_URL'] ?? '').trim(),
      if ((_env['RAILWAY_PUBLIC_DOMAIN'] ?? '').trim().isNotEmpty)
        'https://${(_env['RAILWAY_PUBLIC_DOMAIN'] ?? '').trim()}',
      if ((_env['FLY_APP_NAME'] ?? '').trim().isNotEmpty)
        'https://${(_env['FLY_APP_NAME'] ?? '').trim()}.fly.dev',
    ];
    for (final raw in candidates) {
      if (raw.startsWith('https://') && !isEphemeralTunnelOrigin(raw)) {
        return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
      }
    }
    final dyn = (_dynamicPublicOrigin ?? '').trim();
    if (dyn.startsWith('https://') && !isEphemeralTunnelOrigin(dyn)) {
      return dyn.endsWith('/') ? dyn.substring(0, dyn.length - 1) : dyn;
    }
    return null;
  }

  String? _configuredPublicHttpsOrigin() {
    final perm = _configuredPermanentHttpsOrigin();
    if (perm != null) {
      return perm;
    }
    final dyn = (_dynamicPublicOrigin ?? '').trim();
    if (dyn.startsWith('https://')) {
      return dyn.endsWith('/') ? dyn.substring(0, dyn.length - 1) : dyn;
    }
    final envUrl = (_env['WATSAFE_PUBLIC_URL'] ?? '').trim();
    if (envUrl.startsWith('https://')) {
      return envUrl.endsWith('/')
          ? envUrl.substring(0, envUrl.length - 1)
          : envUrl;
    }
    return null;
  }

  String _resolvePublicRelayOrigin(HttpRequest request, {String? requested}) {
    final perm = _configuredPermanentHttpsOrigin();
    if (perm != null) {
      return perm;
    }
    final dyn = (_dynamicPublicOrigin ?? '').trim();
    if (dyn.isNotEmpty) {
      return dyn.endsWith('/') ? dyn.substring(0, dyn.length - 1) : dyn;
    }
    final envUrl = (_env['WATSAFE_PUBLIC_URL'] ?? '').trim();
    if (envUrl.isNotEmpty) {
      return envUrl.endsWith('/')
          ? envUrl.substring(0, envUrl.length - 1)
          : envUrl;
    }
    if (requested != null && requested.trim().isNotEmpty) {
      final cleaned = requested.trim();
      // If requested is loopback and request carries a public forwarded host, prefer forwarded HTTPS.
      final reqUri = Uri.tryParse(cleaned);
      final fwdProto = (request.headers.value('x-forwarded-proto') ?? '')
          .trim();
      final fwdHost = (request.headers.value('x-forwarded-host') ?? '').trim();
      if (reqUri != null &&
          (reqUri.host == '127.0.0.1' || reqUri.host == 'localhost') &&
          fwdProto == 'https' &&
          fwdHost.isNotEmpty) {
        return 'https://$fwdHost';
      }
      return cleaned.endsWith('/')
          ? cleaned.substring(0, cleaned.length - 1)
          : cleaned;
    }
    final proto = (request.headers.value('x-forwarded-proto') ?? 'http').trim();
    final hostHeader =
        (request.headers.value('x-forwarded-host') ??
                request.headers.value(HttpHeaders.hostHeader))
            ?.trim();
    final host = (hostHeader != null && hostHeader.isNotEmpty)
        ? hostHeader
        : '127.0.0.1:$port';
    return '$proto://$host';
  }

  Map<String, Object?> _hostPresenceFields(
    RelaySessionRecord? session,
    DateTime nowUtc,
  ) {
    final online = session?.isHostOnlineAt(nowUtc, ttl: hostOnlineTtl) ?? false;
    return <String, Object?>{
      'hostOnline': online,
      'hostLastSeenAtUtc': ?session?.hostLastSeenAtUtc?.toIso8601String(),
      'hostDisconnectedAtUtc': ?session?.hostDisconnectedAtUtc
          ?.toIso8601String(),
      'hostProtectionState': session?.hostProtectionState ?? 'off',
    };
  }

  bool _isWebCompanionBond(
    CompanionBondRecord bond, [
    Map<String, Object?>? body,
  ]) {
    if (bond.pushToken != null && bond.pushToken!.trim().isNotEmpty) {
      return false;
    }
    if (body != null &&
        (body.containsKey('httpsReady') ||
            body.containsKey('homeScreenInstalled') ||
            body.containsKey('notificationPermission') ||
            body.containsKey('pushSubscribed'))) {
      return true;
    }
    final p = bond.platform.toLowerCase();
    return p.contains('safari') ||
        p.contains('chrome') ||
        p.contains('web') ||
        p.contains('browser');
  }

  void _syncPairedSnapshot(CompanionBondRecord bond) {
    _pairedDevicesSnapshot.removeWhere(
      (item) =>
          item['pairingSessionId'] == bond.pairingSessionId &&
          item['deviceId'] == bond.deviceId,
    );
    _pairedDevicesSnapshot.add(bond.toDeviceSummaryJson());
  }

  Map<String, Object?> _vapidMismatchFields(CompanionBondRecord bond) {
    final serverKey = _pushProvider.vapidPublicKey;
    final subKey = bond.subscribedVapidPublicKey;
    final mismatch =
        subKey != null &&
        subKey.isNotEmpty &&
        serverKey != null &&
        serverKey.isNotEmpty &&
        subKey != serverKey;
    return <String, Object?>{
      'vapidKeyMismatch': mismatch,
      'pushSubscriptionNeedsRenewal':
          bond.pushSubscriptionNeedsRenewal || mismatch,
      'lastPushErrorCode': ?bond.lastPushErrorCode,
    };
  }

  Future<Map<String, Object?>> _dispatchRecordedSessionAlert({
    required String pairingSessionId,
    required String hostDisplayName,
    required ({SessionAlertRecord alert, bool deduplicated}) recorded,
    required List<CompanionBondRecord> activeBonds,
  }) async {
    final dedupKey = '$pairingSessionId::${recorded.alert.incidentId}';
    PushDispatchSummary summary;
    if (recorded.deduplicated) {
      summary = PushDispatchSummary(
        activeBondCount: activeBonds.where((b) => !b.isRevoked).length,
        pushAttemptedCount: 0,
        pushAcceptedCount: 0,
        pushFailedCount: 0,
        webBondsMissingPushCount: 0,
      );
    } else {
      _reportedIncidentsSnapshot[dedupKey] = recorded.alert.toJson();
      summary = await _pushProvider.dispatchAlertWithSummary(
        bonds: activeBonds,
        alert: recorded.alert,
        hostDisplayName: hostDisplayName,
        onBondUpdated: (updatedBond) async {
          await _store.saveCompanionBond(updatedBond);
          _syncPairedSnapshot(updatedBond);
        },
        onBondSubscriptionExpired: (expiredBond) async {
          await _store.saveCompanionBond(expiredBond);
          _syncPairedSnapshot(expiredBond);
        },
      );
    }
    final delivered =
        recorded.deduplicated ||
        summary.pushAcceptedCount > 0 ||
        (summary.activeBondCount > 0 &&
            summary.pushFailedCount == 0 &&
            summary.webBondsMissingPushCount == 0);
    return <String, Object?>{
      'delivered': delivered,
      'alertRecorded': true,
      'deduplicated': recorded.deduplicated,
      'pairingSessionId': pairingSessionId,
      'incidentId': recorded.alert.incidentId,
      'alertSeq': recorded.alert.alertSeq,
      'deliveryStage': recorded.deduplicated
          ? 'deduplicated'
          : summary.deliveryStage,
      'pushAccepted': summary.pushAcceptedCount > 0,
      'receiptConfirmed': recorded.alert.isReceiptConfirmed,
      'receiptConfirmedAtUtc': ?recorded.alert.receiptConfirmedAtUtc,
      'receiptSource': ?recorded.alert.receiptSource,
      'dispatchedCount': summary.activeBondCount,
      'pushAttemptedCount': summary.pushAttemptedCount,
      'pushAcceptedCount': summary.pushAcceptedCount,
      'pushDispatchedCount': summary.pushAcceptedCount,
      'pushFailedCount': summary.pushFailedCount,
      'webBondsMissingPushCount': summary.webBondsMissingPushCount,
      'pushFailureReasons': summary.failureReasons,
    };
  }

  Future<void> _writePngBytes(HttpResponse response, List<int> bytes) async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType('image', 'png');
    response.headers.set('Cache-Control', 'public, max-age=3600');
    response.add(bytes);
    await response.close();
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

      // Universal Links & Android App Links metadata so installed native apps
      // can open `/pair?code=...` directly when domain links are configured.
      if (method == 'GET' &&
          path == '/.well-known/apple-app-site-association') {
        final appId =
            (_env['APPLE_TEAM_APP_ID'] ?? 'TEAMID.dev.watsafe.temp.watsafe')
                .trim();
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'applinks': <String, Object?>{
            'apps': const <Object>[],
            'details': <Object>[
              <String, Object?>{
                'appID': appId,
                'paths': const <String>['/pair', '/pair/*'],
              },
            ],
          },
        });
        return;
      }

      if (method == 'GET' && path == '/.well-known/assetlinks.json') {
        final pkg = (_env['ANDROID_PACKAGE_NAME'] ?? 'dev.watsafe.temp.watsafe')
            .trim();
        final sha256Cert = (_env['ANDROID_SHA256_CERT_FINGERPRINT'] ?? '')
            .trim();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<Object>[
            <String, Object?>{
              'relation': const <String>[
                'delegate_permission/common.handle_all_urls',
              ],
              'target': <String, Object?>{
                'namespace': 'android_app',
                'package_name': pkg,
                'sha256_cert_fingerprints': sha256Cert.isEmpty
                    ? const <String>[]
                    : <String>[sha256Cert],
              },
            },
          ]),
        );
        await request.response.close();
        return;
      }

      // PWA Web App Manifest & Icons (required by iOS Home Screen Web Push & Android install)
      if (method == 'GET' &&
          (path == '/manifest.webmanifest' || path == '/manifest.json')) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'application',
          'manifest+json',
          charset: 'utf-8',
        );
        request.response.write(CompanionPwaAssets.buildWebManifestJson());
        await request.response.close();
        return;
      }

      if (method == 'GET' && path == '/icons/icon-192.png') {
        await _writePngBytes(request.response, CompanionPwaAssets.icon192Png);
        return;
      }
      if (method == 'GET' && path == '/icons/icon-512.png') {
        await _writePngBytes(request.response, CompanionPwaAssets.icon512Png);
        return;
      }
      if (method == 'GET' &&
          (path == '/icons/apple-touch-icon.png' ||
              path == '/apple-touch-icon.png')) {
        await _writePngBytes(
          request.response,
          CompanionPwaAssets.appleTouchIcon180Png,
        );
        return;
      }
      if (method == 'GET' && path == '/favicon.png') {
        await _writePngBytes(request.response, CompanionPwaAssets.favicon64Png);
        return;
      }

      // Service Worker for mobile Web Push notifications & tap-to-open-event
      if (method == 'GET' && path == '/sw.js') {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'application',
          'javascript',
          charset: 'utf-8',
        );
        request.response.headers.set('Service-Worker-Allowed', '/');
        request.response.headers.set('Cache-Control', 'no-cache');
        request.response.write(CompanionPwaAssets.serviceWorkerJs);
        await request.response.close();
        return;
      }

      // Guided HTTPS iPhone/Android companion web page (`/`, `/pair`, `/companion`)
      if (method == 'GET' &&
          (path == '/' || path == '/pair' || path == '/companion')) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.html;
        request.response.headers.set('Cache-Control', 'no-cache');
        request.response.write(CompanionPwaAssets.companionWebHtml);
        await request.response.close();
        return;
      }

      if (method == 'GET' && path == '/v1/health') {
        final publicHttpsOrigin = _configuredPublicHttpsOrigin();
        final permanentHttpsOrigin = _configuredPermanentHttpsOrigin();
        final envPush = _pushProvider is EnvironmentPushProviderAdapter
            ? _pushProvider
            : null;
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'status': 'ok',
          'storageBackend': _store.backendName,
          'storageDurable': isStorageDurable,
          'storageDurabilityWarning': ?storageDurabilityWarning,
          'swVersion': companionSwVersion,
          'deliveryMode': _pushProvider.isConfigured
              ? 'push_and_live_poll'
              : 'foreground_companion_poll',
          'pushConfigured': _pushProvider.isConfigured,
          'pushProvider': _pushProvider.providerSummary,
          'vapidPublicKey': ?_pushProvider.vapidPublicKey,
          'vapidSubject': ?_pushProvider.vapidSubject,
          'publicHttpsOrigin': ?publicHttpsOrigin,
          'permanentHttpsOrigin': ?permanentHttpsOrigin,
          'isPermanentHttpsOrigin': permanentHttpsOrigin != null,
          'isEphemeralOrigin':
              publicHttpsOrigin != null &&
              isEphemeralTunnelOrigin(publicHttpsOrigin),
          if (envPush != null) ...<String, Object?>{
            'directWebPushReady': envPush.directWebPushReady,
            'webhookConfigured': envPush.hasWebhookConfigured,
            'webhookSenderVerified': envPush.webhookSenderVerified,
          },
        });
        return;
      }

      // Loopback-only endpoint used by `tool/dev_launcher.dart` to register the live
      // verified HTTPS tunnel URL after local relay startup.
      if (method == 'POST' && path == '/v1/admin/public-url') {
        final remote = request.connectionInfo?.remoteAddress;
        if (remote == null || !remote.isLoopback) {
          _writeJson(request.response, HttpStatus.forbidden, <String, Object?>{
            'error': 'LOOPBACK_ONLY',
            'message':
                'Public origin configuration is restricted to local loopback.',
          });
          return;
        }
        final body = await _readJsonBody(request);
        final rawUrl = (body['publicUrl'] as String? ?? '').trim();
        if (rawUrl.isEmpty) {
          _dynamicPublicOrigin = null;
        } else {
          final parsed = Uri.tryParse(rawUrl);
          if (parsed == null ||
              (parsed.scheme != 'https' && parsed.scheme != 'http') ||
              parsed.host.isEmpty) {
            _writeJson(
              request.response,
              HttpStatus.badRequest,
              <String, Object?>{
                'error': 'INVALID_PUBLIC_URL',
                'message': 'Expected a valid http(s) origin URL.',
              },
            );
            return;
          }
          _dynamicPublicOrigin = rawUrl.endsWith('/')
              ? rawUrl.substring(0, rawUrl.length - 1)
              : rawUrl;
        }
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'updated': true,
          'publicOrigin': _dynamicPublicOrigin,
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
            : 'My Laptop';

        RelaySessionRecord? session;
        final existingToken = _extractBearerToken(request);
        if (existingToken != null) {
          session = await _store.findSessionByHostToken(existingToken);
        }

        if (session != null) {
          session.markHostSeen(
            nowUtc,
            displayName: hostDisplayName,
            deviceId: body['hostDeviceId'] as String?,
            protectionState: body['hostProtectionState'] as String?,
          );
          session.activePairingCode = normalizedCode;
          session.codeExpiresAtUtc = expiresAtUtc;
          session.failedCodeAttempts = 0;
          await _store.saveSession(session);
        } else {
          session = RelaySessionRecord(
            pairingSessionId: 'sess_${_randomHex(10)}',
            hostDisplayName: hostDisplayName,
            hostToken: 'host_${_randomHex(20)}',
            createdAtUtc: nowUtc,
            hostDeviceId: (body['hostDeviceId'] as String?)?.trim(),
            activePairingCode: normalizedCode,
            codeExpiresAtUtc: expiresAtUtc,
            failedCodeAttempts: 0,
            hostLastSeenAtUtc: nowUtc,
            hostProtectionState:
                (body['hostProtectionState'] as String?)?.trim() ?? 'off',
          );
          await _store.saveSession(session);
        }

        final effectiveRelayUrl = _resolvePublicRelayOrigin(
          request,
          requested: body['relayUrl'] as String?,
        );
        final permanentOrigin = _configuredPermanentHttpsOrigin();
        final pairingUrl =
            '$effectiveRelayUrl/pair?code=${Uri.encodeQueryComponent(displayCode)}'
            '&session=${Uri.encodeQueryComponent(session.pairingSessionId)}';
        final appDeepLink =
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
          'pairingUrl': pairingUrl,
          'qrPayload': pairingUrl,
          'appDeepLink': appDeepLink,
          'permanentHttpsOrigin': ?permanentOrigin,
          'isEphemeralOrigin': isEphemeralTunnelOrigin(effectiveRelayUrl),
        });
        return;
      }

      // Non-consuming lookup so the phone can display "Connect to Jonathan’s MacBook?"
      // with one Connect button before consuming the single-use code.
      if (method == 'GET' && path == '/v1/pairing/lookup') {
        final nowUtc = _clock().toUtc();
        final clientKey = _clientRateLimitKey(request);
        if (_isClientRateLimited(clientKey, nowUtc)) {
          _writeJson(
            request.response,
            HttpStatus.tooManyRequests,
            <String, Object?>{
              'error': 'TOO_MANY_ATTEMPTS',
              'message': 'Too many incorrect pairing codes. Wait a few minutes or get a new code on your laptop.',
            },
          );
          return;
        }

        final rawCode = request.uri.queryParameters['code'] ?? '';
        final normalizedCode = normalizePairingCode(rawCode);
        if (normalizedCode.isEmpty) {
          _recordFailedPairingAttempt(clientKey, nowUtc);
          _writeJson(request.response, HttpStatus.badRequest, <String, Object?>{
            'error': 'INVALID_PAIRING_CODE',
            'message': 'Enter the 6-character code shown on your laptop.',
          });
          return;
        }

        final candidate = await _store.findSessionByPairingCode(normalizedCode);
        if (candidate == null) {
          _recordFailedPairingAttempt(clientKey, nowUtc);
          _writeJson(request.response, HttpStatus.badRequest, <String, Object?>{
            'error': 'INVALID_OR_EXPIRED_PAIRING_CODE',
            'message': 'That code was not recognized or has already been used. Get a new code on your laptop.',
          });
          return;
        }

        final expiresAt = candidate.codeExpiresAtUtc;
        if (expiresAt == null || !nowUtc.isBefore(expiresAt)) {
          candidate.activePairingCode = null;
          candidate.codeExpiresAtUtc = null;
          await _store.saveSession(candidate);
          _writeJson(request.response, HttpStatus.badRequest, <String, Object?>{
            'error': 'PAIRING_CODE_EXPIRED',
            'message': 'This pairing code expired. Tap "Get new code" on your laptop and scan again.',
          });
          return;
        }

        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'pairingSessionId': candidate.pairingSessionId,
          'hostDisplayName': candidate.hostDisplayName,
          'pairingCode': formatDisplayPairingCode(normalizedCode),
          'expiresAtUtc': expiresAt.toIso8601String(),
          'pushConfigured': _pushProvider.isConfigured,
          'vapidPublicKey': ?_pushProvider.vapidPublicKey,
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
        final clientKey = _clientRateLimitKey(request);
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
          session.markHostSeen(nowUtc);
          if (session.activePairingCode == normalizedCode) {
            session.activePairingCode = null;
            session.codeExpiresAtUtc = null;
          }
          await _store.saveSession(session);
        } else {
          if (_isClientRateLimited(clientKey, nowUtc)) {
            _writeJson(
              request.response,
              HttpStatus.tooManyRequests,
              <String, Object?>{
                'error': 'TOO_MANY_ATTEMPTS',
                'message': 'Too many incorrect pairing attempts. Wait a few minutes or generate a new code on your laptop.',
              },
            );
            return;
          }

          if (normalizedCode.isEmpty) {
            _recordFailedPairingAttempt(clientKey, nowUtc);
            _writeJson(
              request.response,
              HttpStatus.badRequest,
              <String, Object?>{
                'error': 'INVALID_OR_EXPIRED_PAIRING_CODE',
                'message': 'Enter the 6-character code shown on your laptop.',
              },
            );
            return;
          }

          final candidate = await _store.findSessionByPairingCode(
            normalizedCode,
          );
          if (candidate == null) {
            _recordFailedPairingAttempt(clientKey, nowUtc);
            final targetSessionId = body['pairingSessionId'] as String?;
            if (targetSessionId != null && targetSessionId.isNotEmpty) {
              final targeted = await _store.findSessionById(targetSessionId);
              if (targeted != null) {
                targeted.failedCodeAttempts += 1;
                if (targeted.failedCodeAttempts >= maxFailedPairingAttempts) {
                  targeted.activePairingCode = null;
                  targeted.codeExpiresAtUtc = null;
                }
                await _store.saveSession(targeted);
              }
            }
            _writeJson(
              request.response,
              HttpStatus.badRequest,
              <String, Object?>{
                'error': 'INVALID_OR_EXPIRED_PAIRING_CODE',
                'message': 'Pairing code is invalid or has already been used. Get a new code on your laptop.',
              },
            );
            return;
          }

          final expiresAt = candidate.codeExpiresAtUtc;
          if (expiresAt == null || !nowUtc.isBefore(expiresAt)) {
            candidate.activePairingCode = null;
            candidate.codeExpiresAtUtc = null;
            await _store.saveSession(candidate);
            _writeJson(
              request.response,
              HttpStatus.badRequest,
              <String, Object?>{
                'error': 'PAIRING_CODE_EXPIRED',
                'message': 'This pairing code expired. Tap "Get new code" on your laptop.',
              },
            );
            return;
          }

          session = candidate;
          _clearFailedPairingAttempts(clientKey);
          // Consume single-use code immediately so a second client cannot reuse it.
          session.activePairingCode = null;
          session.codeExpiresAtUtc = null;
          session.failedCodeAttempts = 0;
          await _store.saveSession(session);
        }

        final nowIso = nowUtc.toIso8601String();
        final pushToken = (body['pushToken'] as String?)?.trim();
        final hasNativePushToken = pushToken != null && pushToken.isNotEmpty;
        final requestedNotificationsEnabled =
            body['notificationsEnabled'] as bool? ?? (hostToken != null);
        final httpsReady =
            body['httpsReady'] as bool? ??
            (hostToken != null || hasNativePushToken);
        final homeScreenInstalled =
            body['homeScreenInstalled'] as bool? ??
            (hostToken != null || hasNativePushToken);
        final notificationPermission =
            (body['notificationPermission'] as String?)?.trim().isNotEmpty ==
                true
            ? (body['notificationPermission'] as String).trim()
            : (requestedNotificationsEnabled ? 'granted' : 'default');
        final rawChannel =
            (body['notificationChannel'] as String? ??
                    body['deliveryChannel'] as String?)
                ?.trim();

        final explicitDeviceId = (body['deviceId'] as String?)?.trim();
        final resolvedDeviceId =
            explicitDeviceId != null && explicitDeviceId.isNotEmpty
            ? explicitDeviceId
            : 'dev_${++_seq}_${_randomHex(4)}';
        if (explicitDeviceId != null && explicitDeviceId.isNotEmpty) {
          await _store.revokeBond(
            pairingSessionId: session.pairingSessionId,
            deviceId: explicitDeviceId,
          );
          _pairedDevicesSnapshot.removeWhere(
            (item) =>
                item['pairingSessionId'] == session!.pairingSessionId &&
                item['deviceId'] == explicitDeviceId,
          );
        }

        final provisionalBond = CompanionBondRecord(
          bondId: 'bond_${++_seq}_${_randomHex(6)}',
          pairingSessionId: session.pairingSessionId,
          deviceId: resolvedDeviceId,
          displayName:
              (body['displayName'] as String?)?.trim().isNotEmpty == true
              ? (body['displayName'] as String).trim()
              : 'My Phone',
          platform: (body['platform'] as String?)?.trim().isNotEmpty == true
              ? (body['platform'] as String).trim()
              : 'Phone',
          companionToken: 'comp_${_randomHex(20)}',
          pairedAtUtcIso: (body['pairedAtUtc'] as String?) ?? nowIso,
          connected: true,
          pushChannelReady: false,
          notificationsEnabled: false,
          notificationChannel: rawChannel?.isNotEmpty == true
              ? rawChannel!
              : 'foreground_only',
          httpsReady: httpsReady,
          homeScreenInstalled: homeScreenInstalled,
          notificationPermission: notificationPermission,
          pushSubscribed: hasNativePushToken,
          backendPushRegistered: hasNativePushToken,
          pushToken: hasNativePushToken ? pushToken : null,
          webPushEndpoint: (body['webPushEndpoint'] as String?)?.trim(),
          lastSeenAtUtcIso: nowIso,
        );

        final isWebBond =
            hostToken == null && _isWebCompanionBond(provisionalBond, body);
        if (isWebBond) {
          // Web companions become `notificationsEnabled: true` strictly AFTER
          // permission + PushSubscription + `/v1/companion/push-subscription` succeed.
          provisionalBond.notificationsEnabled = false;
          provisionalBond.pushChannelReady = false;
        } else {
          provisionalBond.notificationsEnabled = requestedNotificationsEnabled;
          provisionalBond.pushChannelReady =
              requestedNotificationsEnabled || hostToken != null;
          if (rawChannel == null || rawChannel.isEmpty) {
            provisionalBond.notificationChannel =
                provisionalBond.notificationsEnabled
                ? 'push'
                : 'foreground_only';
          }
        }

        await _store.saveCompanionBond(provisionalBond);
        _syncPairedSnapshot(provisionalBond);
        final summaryJson = provisionalBond.toDeviceSummaryJson();

        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          ...summaryJson,
          'hostDisplayName': session.hostDisplayName,
          'companionToken': provisionalBond.companionToken,
          'pushConfigured': _pushProvider.isConfigured,
          'vapidPublicKey': ?_pushProvider.vapidPublicKey,
          'permanentHttpsOrigin': ?_configuredPermanentHttpsOrigin(),
          'deliveryMode': _pushProvider.isConfigured
              ? 'push_and_live_poll'
              : 'foreground_poll',
          ..._hostPresenceFields(session, nowUtc),
        });
        return;
      }

      // Mints a short-lived, single-use 6-character setup code so a paired iPhone
      // user moving from Mobile Safari into the isolated iOS Home Screen web app
      // transfers their existing bond cleanly without putting tokens in URLs.
      if (method == 'POST' && path == '/v1/companion/handoff-code') {
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
              'message': 'Companion session is unpaired or revoked.',
            },
          );
          return;
        }

        final nowUtc = _clock().toUtc();
        final expiresAtUtc = nowUtc.add(handoffCodeTtl);
        final displayCode = _generatePairingCode();
        bond.activeHandoffCode = normalizePairingCode(displayCode);
        bond.handoffExpiresAtUtc = expiresAtUtc;
        bond.lastSeenAtUtcIso = nowUtc.toIso8601String();
        await _store.saveCompanionBond(bond);

        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'handoffCode': displayCode,
          'expiresInSeconds': handoffCodeTtl.inSeconds,
          'expiresAtUtc': expiresAtUtc.toIso8601String(),
        });
        return;
      }

      // Consumes a single-use Safari -> Home Screen handoff code, keeping the same
      // paired device bond and rotating the companion bearer token securely.
      if (method == 'POST' && path == '/v1/companion/claim-handoff') {
        final body = await _readJsonBody(request);
        final forbidden = detectForbiddenSensitiveField(body);
        if (forbidden != null) {
          _writePrivacyViolation(request.response, forbidden);
          return;
        }
        final nowUtc = _clock().toUtc();
        final clientKey = _clientRateLimitKey(request);
        if (_isClientRateLimited(clientKey, nowUtc)) {
          _writeJson(
            request.response,
            HttpStatus.tooManyRequests,
            <String, Object?>{
              'error': 'TOO_MANY_ATTEMPTS',
              'message': 'Too many incorrect setup codes. Wait a few minutes or scan a fresh QR code from your laptop.',
            },
          );
          return;
        }

        final rawCode = (body['handoffCode'] as String? ?? '').trim();
        final normalizedCode = normalizePairingCode(rawCode);
        if (normalizedCode.isEmpty) {
          _recordFailedPairingAttempt(clientKey, nowUtc);
          _writeJson(request.response, HttpStatus.badRequest, <String, Object?>{
            'error': 'INVALID_HANDOFF_CODE',
            'message': 'Enter the 6-character Home Screen setup code.',
          });
          return;
        }

        final bond = await _store.findActiveBondByHandoffCode(normalizedCode);
        if (bond == null) {
          _writeJson(request.response, HttpStatus.notFound, <String, Object?>{
            'error': 'HANDOFF_CODE_NOT_FOUND',
            'message': 'Setup code was not found or has already been used.',
          });
          return;
        }

        final expiresAt = bond.handoffExpiresAtUtc;
        if (expiresAt == null || !nowUtc.isBefore(expiresAt)) {
          bond.activeHandoffCode = null;
          bond.handoffExpiresAtUtc = null;
          await _store.saveCompanionBond(bond);
          _writeJson(request.response, HttpStatus.badRequest, <String, Object?>{
            'error': 'HANDOFF_CODE_EXPIRED',
            'message': 'This Home Screen setup code expired. Open Safari or scan a new QR code on your laptop.',
          });
          return;
        }

        _clearFailedPairingAttempts(clientKey);
        bond.activeHandoffCode = null;
        bond.handoffExpiresAtUtc = null;
        bond.previousCompanionToken = null;
        bond.previousTokenGraceUntilUtc = null;
        bond.companionToken = 'comp_${_randomHex(20)}';
        bond.tokenRefreshedAtUtcIso = nowUtc.toIso8601String();
        if (body['platform'] is String &&
            (body['platform'] as String).trim().isNotEmpty) {
          bond.platform = (body['platform'] as String).trim();
        }
        if (body['httpsReady'] is bool) {
          bond.httpsReady = body['httpsReady'] as bool;
        }
        if (body['homeScreenInstalled'] is bool) {
          bond.homeScreenInstalled = body['homeScreenInstalled'] as bool;
        }
        bond.connected = true;
        bond.lastSeenAtUtcIso = nowUtc.toIso8601String();
        await _store.saveCompanionBond(bond);
        _syncPairedSnapshot(bond);

        final session = await _store.findSessionById(bond.pairingSessionId);
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          ...bond.toDeviceSummaryJson(),
          'hostDisplayName': session?.hostDisplayName ?? 'My Laptop',
          'companionToken': bond.companionToken,
          'pushConfigured': _pushProvider.isConfigured,
          'vapidPublicKey': ?_pushProvider.vapidPublicKey,
          'permanentHttpsOrigin': ?_configuredPermanentHttpsOrigin(),
          ..._hostPresenceFields(session, nowUtc),
        });
        return;
      }

      // Rotates the companion bearer token in-place with a short grace window so
      // concurrent requests or flaky mobile networks never invalidate a valid pairing.
      if (method == 'POST' && path == '/v1/companion/token/refresh') {
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
              'message': 'Companion session is unpaired or revoked.',
            },
          );
          return;
        }

        final nowUtc = _clock().toUtc();
        final nowIso = nowUtc.toIso8601String();
        if (bond.companionToken == companionToken) {
          bond.previousCompanionToken = bond.companionToken;
          bond.previousTokenGraceUntilUtc = nowUtc.add(tokenRefreshGraceWindow);
          bond.companionToken = 'comp_${_randomHex(20)}';
          bond.tokenRefreshedAtUtcIso = nowIso;
        }
        bond.connected = true;
        bond.lastSeenAtUtcIso = nowIso;
        await _store.saveCompanionBond(bond);
        _syncPairedSnapshot(bond);

        final session = await _store.findSessionById(bond.pairingSessionId);
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          ...bond.toDeviceSummaryJson(),
          'companionToken': bond.companionToken,
          'tokenRefreshedAtUtc': bond.tokenRefreshedAtUtcIso ?? nowIso,
          'hostDisplayName': session?.hostDisplayName ?? 'My Laptop',
          'pushConfigured': _pushProvider.isConfigured,
          'vapidPublicKey': ?_pushProvider.vapidPublicKey,
          'permanentHttpsOrigin': ?_configuredPermanentHttpsOrigin(),
          ..._hostPresenceFields(session, nowUtc),
        });
        return;
      }

      // Registers and validates a real RFC 8030 / RFC 8291 Web Push subscription
      // (`endpoint`, `p256dh`, `auth`) for the authenticated companion bond.
      if ((method == 'POST' || method == 'DELETE') &&
          path == '/v1/companion/push-subscription') {
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
              'message': 'Companion session is unpaired or revoked.',
            },
          );
          return;
        }

        if (method == 'DELETE') {
          bond.clearWebPushSubscription(clearErrorTelemetry: true);
          bond.lastSeenAtUtcIso = _clock().toUtc().toIso8601String();
          await _store.saveCompanionBond(bond);
          _syncPairedSnapshot(bond);
          _writeJson(request.response, HttpStatus.ok, <String, Object?>{
            ...bond.toDeviceSummaryJson(),
            ..._vapidMismatchFields(bond),
          });
          return;
        }

        final body = await _readJsonBody(request);
        final forbidden = detectForbiddenSensitiveField(body);
        if (forbidden != null) {
          _writePrivacyViolation(request.response, forbidden);
          return;
        }

        final subscribedKey =
            (body['subscribedVapidPublicKey'] as String? ?? '').trim();
        final serverVapidKey = _pushProvider.vapidPublicKey;
        if (subscribedKey.isNotEmpty &&
            serverVapidKey != null &&
            serverVapidKey.isNotEmpty &&
            subscribedKey != serverVapidKey) {
          _writeJson(request.response, HttpStatus.conflict, <String, Object?>{
            'error': 'VAPID_KEY_MISMATCH',
            'vapidPublicKey': serverVapidKey,
            'message': 'Server notification key changed. Refreshing subscription automatically.',
          });
          return;
        }

        final endpoint = (body['endpoint'] as String? ?? '').trim();
        final p256dh = (body['p256dh'] as String? ?? '').trim();
        final auth = (body['auth'] as String? ?? '').trim();

        try {
          WebPushSubscriptionData.validate(
            endpointRaw: endpoint,
            p256dhRaw: p256dh,
            authRaw: auth,
          );
        } on FormatException catch (err) {
          _writeJson(request.response, HttpStatus.badRequest, <String, Object?>{
            'error': 'INVALID_WEB_PUSH_SUBSCRIPTION',
            'message': err.message,
          });
          return;
        }

        if (body['platform'] is String &&
            (body['platform'] as String).trim().isNotEmpty) {
          bond.platform = (body['platform'] as String).trim();
        }
        final httpsReady = body['httpsReady'] as bool? ?? true;
        final homeScreenInstalled =
            body['homeScreenInstalled'] as bool? ?? true;
        final permission =
            (body['notificationPermission'] as String?)?.trim() ?? 'granted';

        bond.httpsReady = httpsReady;
        bond.homeScreenInstalled = homeScreenInstalled;
        bond.notificationPermission = permission;
        bond.webPushEndpoint = endpoint;
        bond.webPushP256dh = p256dh;
        bond.webPushAuth = auth;
        bond.subscribedVapidPublicKey = subscribedKey.isNotEmpty
            ? subscribedKey
            : serverVapidKey;
        bond.lastPushStatusCode = null;
        bond.lastPushErrorCode = null;
        bond.pushSubscribed = true;
        bond.backendPushRegistered = true;

        final ready =
            httpsReady &&
            homeScreenInstalled &&
            permission == 'granted' &&
            bond.hasValidWebPushSubscription;
        bond.notificationsEnabled = ready;
        bond.pushChannelReady = ready;
        bond.notificationChannel = ready ? 'web_push' : 'pending_setup';
        bond.connected = true;
        final nowUtc = _clock().toUtc();
        bond.lastSeenAtUtcIso = nowUtc.toIso8601String();

        await _store.saveCompanionBond(bond);
        _syncPairedSnapshot(bond);

        final session = await _store.findSessionById(bond.pairingSessionId);
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          ...bond.toDeviceSummaryJson(),
          ..._vapidMismatchFields(bond),
          'hostDisplayName': session?.hostDisplayName ?? 'My Laptop',
          'pushConfigured': _pushProvider.isConfigured,
          'vapidPublicKey': ?_pushProvider.vapidPublicKey,
          'permanentHttpsOrigin': ?_configuredPermanentHttpsOrigin(),
          ..._hostPresenceFields(session, nowUtc),
        });
        return;
      }

      // Reads or updates the paired phone's notification permission & readiness state
      // so the laptop's Home row accurately reflects whether notifications are enabled.
      if ((method == 'GET' || method == 'POST') &&
          path == '/v1/companion/status') {
        final body = method == 'POST'
            ? await _readJsonBody(request)
            : const <String, Object?>{};
        final forbidden = detectForbiddenSensitiveField(body);
        if (forbidden != null) {
          _writePrivacyViolation(request.response, forbidden);
          return;
        }
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
              'message': 'Companion session is unpaired or revoked.',
            },
          );
          return;
        }
        final nowUtc = _clock().toUtc();
        final session = await _store.findSessionById(bond.pairingSessionId);
        if (method == 'GET') {
          bond.connected = true;
          bond.lastSeenAtUtcIso = nowUtc.toIso8601String();
          await _store.saveCompanionBond(bond);
          _syncPairedSnapshot(bond);
          _writeJson(request.response, HttpStatus.ok, <String, Object?>{
            ...bond.toDeviceSummaryJson(),
            ..._vapidMismatchFields(bond),
            'hostDisplayName': session?.hostDisplayName ?? 'My Laptop',
            'pushConfigured': _pushProvider.isConfigured,
            'vapidPublicKey': ?_pushProvider.vapidPublicKey,
            'permanentHttpsOrigin': ?_configuredPermanentHttpsOrigin(),
            ..._hostPresenceFields(session, nowUtc),
          });
          return;
        }

        if (body['platform'] is String &&
            (body['platform'] as String).trim().isNotEmpty) {
          bond.platform = (body['platform'] as String).trim();
        }
        if (body['httpsReady'] is bool) {
          bond.httpsReady = body['httpsReady'] as bool;
        }
        if (body['homeScreenInstalled'] is bool) {
          bond.homeScreenInstalled = body['homeScreenInstalled'] as bool;
        }
        if (body['notificationPermission'] is String &&
            (body['notificationPermission'] as String).trim().isNotEmpty) {
          bond.notificationPermission =
              (body['notificationPermission'] as String).trim();
        }
        if (body['subscribedVapidPublicKey'] is String) {
          final sk = (body['subscribedVapidPublicKey'] as String).trim();
          bond.subscribedVapidPublicKey = sk.isEmpty ? null : sk;
        }
        if (body['pushSubscribed'] is bool) {
          bond.pushSubscribed = body['pushSubscribed'] as bool;
          if (!bond.pushSubscribed) {
            bond.clearWebPushSubscription();
          }
        }
        if (body['pushToken'] is String) {
          final tok = (body['pushToken'] as String).trim();
          bond.pushToken = tok.isEmpty ? null : tok;
        }
        if (body['webPushEndpoint'] is String) {
          final ep = (body['webPushEndpoint'] as String).trim();
          bond.webPushEndpoint = ep.isEmpty ? null : ep;
        }

        final rawChan =
            (body['notificationChannel'] as String? ??
                    body['deliveryChannel'] as String?)
                ?.trim();
        if (rawChan != null && rawChan.isNotEmpty) {
          bond.notificationChannel = rawChan;
        }

        if (_isWebCompanionBond(bond, body)) {
          final mismatchInfo = _vapidMismatchFields(bond);
          final needsRenewal =
              mismatchInfo['pushSubscriptionNeedsRenewal'] == true;
          // Enforce strict Web Push readiness: never report `notificationsEnabled`
          // unless HTTPS + Home Screen (on iOS) + permission + subscription + backend registration all hold!
          final fullReady =
              bond.httpsReady &&
              bond.homeScreenInstalled &&
              bond.notificationPermission == 'granted' &&
              bond.pushSubscribed &&
              bond.backendPushRegistered &&
              bond.hasValidWebPushSubscription &&
              !needsRenewal;
          bond.notificationsEnabled = fullReady;
          bond.pushChannelReady = fullReady;
          if (fullReady) {
            bond.notificationChannel = 'web_push';
          } else if (!bond.httpsReady) {
            bond.notificationChannel = 'needs_https';
          } else if (!bond.homeScreenInstalled) {
            bond.notificationChannel = 'needs_home_screen';
          } else if (bond.notificationPermission == 'denied') {
            bond.notificationChannel = 'permission_denied';
          } else if (needsRenewal) {
            bond.notificationChannel = 'needs_push_renewal';
          } else {
            bond.notificationChannel = 'pending_setup';
          }
        } else if (body['notificationsEnabled'] is bool) {
          bond.notificationsEnabled = body['notificationsEnabled'] as bool;
          bond.pushChannelReady = bond.notificationsEnabled;
          if (bond.notificationsEnabled) {
            bond.notificationPermission = 'granted';
            bond.pushSubscribed = true;
            bond.backendPushRegistered = true;
          }
        }

        bond.connected = true;
        bond.lastSeenAtUtcIso = nowUtc.toIso8601String();
        await _store.saveCompanionBond(bond);
        _syncPairedSnapshot(bond);

        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          ...bond.toDeviceSummaryJson(),
          ..._vapidMismatchFields(bond),
          'hostDisplayName': session?.hostDisplayName ?? 'My Laptop',
          'pushConfigured': _pushProvider.isConfigured,
          'vapidPublicKey': ?_pushProvider.vapidPublicKey,
          'permanentHttpsOrigin': ?_configuredPermanentHttpsOrigin(),
          ..._hostPresenceFields(session, nowUtc),
        });
        return;
      }

      // Sends a real end-to-end test alert from the phone companion (immediate or
      // delayed up to 10s so the user can lock their phone screen and verify delivery).
      if (method == 'POST' && path == '/v1/companion/test-alert') {
        final body = await _readJsonBody(request);
        final forbidden = detectForbiddenSensitiveField(body);
        if (forbidden != null) {
          _writePrivacyViolation(request.response, forbidden);
          return;
        }
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
              'message': 'Companion session is unpaired or revoked.',
            },
          );
          return;
        }

        final delaySeconds = ((body['delaySeconds'] as num?)?.toInt() ?? 0)
            .clamp(0, 10);
        if (delaySeconds > 0) {
          await Future<void>.delayed(Duration(seconds: delaySeconds));
        }

        final session = await _store.findSessionById(bond.pairingSessionId);
        final hostDisplayName = session?.hostDisplayName ?? 'My Laptop';
        final nowIso = _clock().toUtc().toIso8601String();
        final incidentId = 'test_comp_${++_seq}_${_randomHex(4)}';

        // Reuse the latest known laptop location from this session if available so
        // tapping the test notification opens an Activity event with realistic status.
        AlertLocationData? latestLocation;
        var locStatus = 'unavailable';
        final existingAlerts = await _store.listAlertsAfterSeq(
          pairingSessionId: bond.pairingSessionId,
          afterSeq: 0,
        );
        for (var i = existingAlerts.length - 1; i >= 0; i--) {
          if (existingAlerts[i].location != null) {
            final loc = existingAlerts[i].location!;
            latestLocation = AlertLocationData(
              latitude: loc.latitude,
              longitude: loc.longitude,
              accuracyMeters: loc.accuracyMeters,
              capturedAtUtc: loc.capturedAtUtc,
              isLastKnown: true,
              isApproximate: loc.isApproximate,
            );
            locStatus = 'lastKnown';
            break;
          }
        }

        final activeBonds = await _store.listActiveBondsForSession(
          bond.pairingSessionId,
        );
        final recorded = await _store.recordSessionAlert(
          pairingSessionId: bond.pairingSessionId,
          incidentId: incidentId,
          sessionId: bond.pairingSessionId,
          kind: 'companionTestAlert',
          detectorType: 'test_alert',
          triggeredAtUtc: nowIso,
          triggerSummary:
              'Test alert requested from ${bond.displayName} for $hostDisplayName',
          createdAtUtc: nowIso,
          hostDisplayName: hostDisplayName,
          isTest: true,
          location: latestLocation,
          locationStatus: locStatus,
        );

        final dispatchFields = await _dispatchRecordedSessionAlert(
          pairingSessionId: bond.pairingSessionId,
          hostDisplayName: hostDisplayName,
          recorded: recorded,
          activeBonds: activeBonds,
        );

        _writeJson(request.response, HttpStatus.ok, dispatchFields);
        return;
      }

      // Allows the companion phone itself to disconnect and revoke its token & push bond.
      if (method == 'POST' && path == '/v1/companion/disconnect') {
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
        if (bond != null) {
          await _store.revokeBond(
            pairingSessionId: bond.pairingSessionId,
            deviceId: bond.deviceId,
          );
          _pairedDevicesSnapshot.removeWhere(
            (item) =>
                item['pairingSessionId'] == bond.pairingSessionId &&
                item['deviceId'] == bond.deviceId,
          );
        }
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'disconnected': true,
        });
        return;
      }

      // Installation-scoped reset: revokes ONLY this host installation's pairing
      // session, push bonds, and stored session alerts without affecting any other user.
      if (method == 'POST' && path == '/v1/pairing/session/revoke') {
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
          _writeJson(request.response, HttpStatus.ok, <String, Object?>{
            'revoked': false,
          });
          return;
        }
        final sessionId = session.pairingSessionId;
        await _store.revokeSessionAndBonds(sessionId);
        _pairedDevicesSnapshot.removeWhere(
          (item) => item['pairingSessionId'] == sessionId,
        );
        _reportedIncidentsSnapshot.removeWhere(
          (key, _) => key.startsWith('$sessionId::'),
        );
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'revoked': true,
          'pairingSessionId': sessionId,
        });
        return;
      }

      // Host laptop presence heartbeat & graceful offline notification so the
      // phone companion distinguishes "Laptop offline" from a disconnected pairing.
      if (method == 'POST' && path == '/v1/host/heartbeat') {
        final body = await _readJsonBody(request);
        final forbidden = detectForbiddenSensitiveField(body);
        if (forbidden != null) {
          _writePrivacyViolation(request.response, forbidden);
          return;
        }
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
              'message': 'Unknown or revoked host session token.',
            },
          );
          return;
        }
        final nowUtc = _clock().toUtc();
        session.markHostSeen(
          nowUtc,
          displayName: body['hostDisplayName'] as String?,
          deviceId: body['hostDeviceId'] as String?,
          protectionState: body['hostProtectionState'] as String?,
        );
        await _store.saveSession(session);
        final bonds = await _store.listActiveBondsForSession(
          session.pairingSessionId,
        );
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'ok': true,
          'pairingSessionId': session.pairingSessionId,
          'hostDisplayName': session.hostDisplayName,
          'pushConfigured': _pushProvider.isConfigured,
          'permanentHttpsOrigin': ?_configuredPermanentHttpsOrigin(),
          ..._hostPresenceFields(session, nowUtc),
          'devices': bonds
              .map((b) => b.toDeviceSummaryJson())
              .toList(growable: false),
        });
        return;
      }

      if (method == 'POST' && path == '/v1/host/offline') {
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
              'message': 'Unknown or revoked host session token.',
            },
          );
          return;
        }
        final nowUtc = _clock().toUtc();
        session.hostDisconnectedAtUtc = nowUtc;
        await _store.saveSession(session);
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'ok': true,
          'pairingSessionId': session.pairingSessionId,
          ..._hostPresenceFields(session, nowUtc),
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
        final nowUtc = _clock().toUtc();
        session.markHostSeen(nowUtc);
        await _store.saveSession(session);
        final bonds = await _store.listActiveBondsForSession(
          session.pairingSessionId,
        );
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'pairingSessionId': session.pairingSessionId,
          'hostDisplayName': session.hostDisplayName,
          'pushConfigured': _pushProvider.isConfigured,
          'permanentHttpsOrigin': ?_configuredPermanentHttpsOrigin(),
          ..._hostPresenceFields(session, nowUtc),
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
        final hostToken = _extractBearerToken(request);
        RelaySessionRecord? session;
        if (hostToken != null) {
          session = await _store.findSessionByHostToken(hostToken);
          if (session != null) {
            session.markHostSeen(_clock().toUtc());
            await _store.saveSession(session);
          }
        }
        final commandName = (body['command'] as String? ?? '').trim();
        if (commandName == 'send_test_push' && session != null) {
          final nowIso = _clock().toUtc().toIso8601String();
          final incidentId = 'test_cmd_${++_seq}_${_randomHex(4)}';
          final targetDeviceId = (body['deviceId'] as String? ?? '').trim();
          final allBonds = await _store.listActiveBondsForSession(
            session.pairingSessionId,
          );
          final targetBonds = targetDeviceId.isEmpty
              ? allBonds
              : allBonds.where((b) => b.deviceId == targetDeviceId).toList();
          final recorded = await _store.recordSessionAlert(
            pairingSessionId: session.pairingSessionId,
            incidentId: incidentId,
            sessionId: session.pairingSessionId,
            kind: 'companionTestAlert',
            detectorType: 'test_alert',
            triggeredAtUtc: nowIso,
            triggerSummary:
                (body['summary'] as String?)?.trim().isNotEmpty == true
                ? (body['summary'] as String).trim()
                : 'Test alert sent from ${session.hostDisplayName}',
            createdAtUtc: nowIso,
            hostDisplayName: session.hostDisplayName,
            isTest: true,
            locationStatus: 'notRequested',
          );
          final dispatchFields = await _dispatchRecordedSessionAlert(
            pairingSessionId: session.pairingSessionId,
            hostDisplayName: session.hostDisplayName,
            recorded: recorded,
            activeBonds: targetBonds.isEmpty ? allBonds : targetBonds,
          );
          _writeJson(request.response, HttpStatus.ok, <String, Object?>{
            ...dispatchFields,
            'commandId': 'cmd_${++_seq}',
            'deviceId': body['deviceId'],
            'command': body['command'],
          });
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

        final nowUtc = _clock().toUtc();
        final nowIso = nowUtc.toIso8601String();
        final incidentId =
            (body['incidentId'] as String?)?.trim().isNotEmpty == true
            ? (body['incidentId'] as String).trim()
            : 'inc_${++_seq}_${_randomHex(4)}';
        final hostNameOverride = (body['deviceName'] as String?)?.trim();
        final isTestIncident = body['isTest'] as bool? ?? false;
        session.markHostSeen(
          nowUtc,
          displayName: hostNameOverride,
          protectionState: isTestIncident ? null : 'triggered',
        );
        await _store.saveSession(session);

        AlertLocationData? initialLocation;
        final rawLoc = body['location'];
        if (rawLoc is Map) {
          initialLocation = AlertLocationData.fromJson(
            Map<String, Object?>.from(rawLoc),
          );
        }
        final locStatus =
            (body['locationStatus'] as String?) ??
            (initialLocation != null ? 'attached' : 'notRequested');

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
              (body['triggerSummary'] as String?) ?? 'Alarm triggered',
          createdAtUtc: nowIso,
          peakMotionScore: (body['peakMotionScore'] as num?)?.toDouble(),
          hostDisplayName: session.hostDisplayName,
          isTest: body['isTest'] as bool? ?? false,
          location: initialLocation,
          locationStatus: locStatus,
        );

        final dispatchFields = await _dispatchRecordedSessionAlert(
          pairingSessionId: session.pairingSessionId,
          hostDisplayName: session.hostDisplayName,
          recorded: recorded,
          activeBonds: activeBonds,
        );

        _writeJson(request.response, HttpStatus.ok, dispatchFields);
        return;
      }

      // Asynchronous location update from the protected device once a fix arrives.
      // Never triggers a second push notification; updates the authenticated event record.
      if (method == 'POST' && path == '/v1/incidents/location') {
        final body = await _readJsonBody(request);
        final forbidden = detectForbiddenSensitiveField(body);
        if (forbidden != null) {
          _writePrivacyViolation(request.response, forbidden);
          return;
        }
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

        session.markHostSeen(_clock().toUtc());
        await _store.saveSession(session);

        final incidentId = (body['incidentId'] as String? ?? '').trim();
        if (incidentId.isEmpty) {
          _writeJson(request.response, HttpStatus.badRequest, <String, Object?>{
            'error': 'MISSING_INCIDENT_ID',
            'message': 'incidentId is required.',
          });
          return;
        }

        AlertLocationData? location;
        final rawLoc = body['location'];
        if (rawLoc is Map) {
          location = AlertLocationData.fromJson(
            Map<String, Object?>.from(rawLoc),
          );
        }
        final locationStatus =
            (body['locationStatus'] as String?) ??
            (location != null ? 'attached' : 'unavailable');

        final updated = await _store.updateSessionAlertLocation(
          pairingSessionId: session.pairingSessionId,
          incidentId: incidentId,
          location: location,
          locationStatus: locationStatus,
        );
        if (updated == null) {
          _writeJson(request.response, HttpStatus.notFound, <String, Object?>{
            'error': 'INCIDENT_NOT_FOUND',
            'message': 'No matching incident found in this session.',
          });
          return;
        }

        final dedupKey = '${session.pairingSessionId}::$incidentId';
        _reportedIncidentsSnapshot[dedupKey] = updated.toJson();

        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'updated': true,
          'incidentId': incidentId,
          'updatedSeq': updated.effectiveSeq,
          'locationStatus': updated.locationStatus,
        });
        return;
      }

      // Phone receipt acknowledgement from Service Worker (`push_sw`) or active
      // companion poll (`companion_poll`) so WATSafe distinguishes "push service
      // accepted" from confirmed phone receipt.
      if (method == 'POST' &&
          path.startsWith('/v1/companion/events/') &&
          path.endsWith('/ack')) {
        final body = await _readJsonBody(request);
        final forbidden = detectForbiddenSensitiveField(body);
        if (forbidden != null) {
          _writePrivacyViolation(request.response, forbidden);
          return;
        }
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
              'message': 'Companion session is unpaired or revoked.',
            },
          );
          return;
        }
        final middle = path.substring(
          '/v1/companion/events/'.length,
          path.length - '/ack'.length,
        );
        final incidentId = Uri.decodeComponent(middle).trim();
        if (incidentId.isEmpty) {
          _writeJson(request.response, HttpStatus.badRequest, <String, Object?>{
            'error': 'MISSING_INCIDENT_ID',
            'message': 'incidentId is required.',
          });
          return;
        }
        final rawSource = (body['source'] as String? ?? 'companion_ack').trim();
        const allowedSources = <String>{
          'push_sw',
          'companion_poll',
          'companion_ack',
        };
        final receiptSource = allowedSources.contains(rawSource)
            ? rawSource
            : 'companion_ack';
        final nowIso = _clock().toUtc().toIso8601String();
        final updated = await _store.confirmSessionAlertReceipt(
          pairingSessionId: bond.pairingSessionId,
          incidentId: incidentId,
          confirmedAtUtc: nowIso,
          receiptSource: receiptSource,
        );
        if (updated == null) {
          _writeJson(request.response, HttpStatus.notFound, <String, Object?>{
            'error': 'EVENT_NOT_FOUND',
            'message': 'Event not found for this paired session.',
          });
          return;
        }
        bond.connected = true;
        bond.lastSeenAtUtcIso = nowIso;
        bond.lastReceiptAtUtcIso = updated.receiptConfirmedAtUtc ?? nowIso;
        bond.lastReceiptIncidentId = incidentId;
        bond.lastReceiptSource = updated.receiptSource ?? receiptSource;
        await _store.saveCompanionBond(bond);
        _syncPairedSnapshot(bond);
        final dedupKey = '${bond.pairingSessionId}::$incidentId';
        _reportedIncidentsSnapshot[dedupKey] = updated.toJson();

        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'acknowledged': true,
          'incidentId': incidentId,
          'receiptConfirmed': true,
          'receiptConfirmedAtUtc': updated.receiptConfirmedAtUtc,
          'receiptSource': updated.receiptSource,
          'updatedSeq': updated.effectiveSeq,
        });
        return;
      }

      // Authenticated single-event lookup (protects precise coordinates behind
      // authorized companion or host bearer token).
      if (method == 'GET' && path.startsWith('/v1/companion/events/')) {
        final token = _extractBearerToken(request);
        if (token == null) {
          _writeJson(
            request.response,
            HttpStatus.unauthorized,
            <String, Object?>{
              'error': 'UNAUTHORIZED_EVENT_ACCESS',
              'message': 'Authenticated session token required to access event details and location.',
            },
          );
          return;
        }
        String? authorizedSessionId;
        final bond = await _store.findActiveBondByCompanionToken(token);
        if (bond != null) {
          authorizedSessionId = bond.pairingSessionId;
        } else {
          final hostSession = await _store.findSessionByHostToken(token);
          authorizedSessionId = hostSession?.pairingSessionId;
        }
        if (authorizedSessionId == null) {
          _writeJson(
            request.response,
            HttpStatus.unauthorized,
            <String, Object?>{
              'error': 'UNAUTHORIZED_EVENT_ACCESS',
              'message': 'Session is unpaired, revoked, or unauthorized.',
            },
          );
          return;
        }
        final incidentId = Uri.decodeComponent(
          path.substring('/v1/companion/events/'.length),
        );
        final alert = await _store.findAlertByIncidentId(
          pairingSessionId: authorizedSessionId,
          incidentId: incidentId,
        );
        if (alert == null) {
          _writeJson(request.response, HttpStatus.notFound, <String, Object?>{
            'error': 'EVENT_NOT_FOUND',
            'message': 'Event not found for this paired session.',
          });
          return;
        }
        _writeJson(request.response, HttpStatus.ok, alert.toJson());
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

        final nowUtc = _clock().toUtc();
        bond.connected = true;
        bond.lastSeenAtUtcIso = nowUtc.toIso8601String();
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
          'hostDisplayName': session?.hostDisplayName ?? 'My Laptop',
          'deviceId': bond.deviceId,
          'connected': true,
          'notificationsEnabled': bond.notificationsEnabled,
          'backendPushRegistered': bond.backendPushRegistered,
          ..._vapidMismatchFields(bond),
          'pushConfigured': _pushProvider.isConfigured,
          'vapidPublicKey': ?_pushProvider.vapidPublicKey,
          'permanentHttpsOrigin': ?_configuredPermanentHttpsOrigin(),
          'deliveryMode': _pushProvider.isConfigured
              ? 'push_and_live_poll'
              : 'foreground_poll',
          ..._hostPresenceFields(session, nowUtc),
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
      'message': 'Payloads must never contain camera frames, images, PIN material, or database credentials.',
    });
  }

  void _applyCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set(
      'Access-Control-Allow-Methods',
      'GET, POST, PATCH, DELETE, OPTIONS',
    );
    response.headers.set(
      'Access-Control-Allow-Headers',
      'Authorization, Content-Type',
    );
    response.headers.set(
      'Access-Control-Expose-Headers',
      'X-WATSafe-Companion, X-WATSafe-SW-Version',
    );
    response.headers.set('X-WATSafe-Companion', '1');
    response.headers.set('X-WATSafe-SW-Version', companionSwVersion);
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
