import '../core/contracts/platform_contracts.dart';
import '../core/models/detector_models.dart';
import '../core/models/incident_models.dart';

/// Default local-first implementation of [RemoteNotificationAdapter].
///
/// Explicitly reports `CapabilityStatus.notConfigured` and returns an empty
/// paired-device list until the Backend & Notifications teammate connects
/// authenticated pairing and APNs/FCM push relay.
class UnconfiguredRemoteNotificationService
    implements RemoteNotificationAdapter {
  const UnconfiguredRemoteNotificationService();

  @override
  Future<NotificationServiceStatus> getStatus() async {
    return const NotificationServiceStatus(
      capabilityStatus: CapabilityStatus.notConfigured,
      summary: 'Not configured',
      detail:
          'Remote device pairing and APNs/FCM push notifications are not configured in this local milestone. '
          'Server credentials remain strictly server-side once the backend service is deployed.',
    );
  }

  @override
  Future<List<PairedDeviceSummary>> listPairedDevices() async {
    // Never fabricate paired devices; only return real paired devices when configured.
    return const <PairedDeviceSummary>[];
  }

  @override
  Future<NotificationDispatchResult> sendIncidentAlert(
    IncidentRecord incident,
  ) async {
    return const NotificationDispatchResult(
      delivered: false,
      capabilityStatus: CapabilityStatus.notConfigured,
      message: 'Not configured (local-only milestone)',
    );
  }
}
