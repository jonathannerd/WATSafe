import 'package:flutter_test/flutter_test.dart';
import 'package:watsafe/core/models/settings_models.dart';

void main() {
  group('SafeZone settings persistence', () {
    test('round-trips a local zone and clamps its radius', () {
      const zone = SafeZone(
        id: 'zone_home',
        name: 'Home',
        latitude: 43.4723,
        longitude: -80.5449,
        radiusMeters: 350,
        enabled: false,
      );

      final restored = SafeZone.fromJson(zone.toJson());

      expect(restored.id, 'zone_home');
      expect(restored.name, 'Home');
      expect(restored.latitude, 43.4723);
      expect(restored.longitude, -80.5449);
      expect(restored.radiusMeters, 350);
      expect(restored.enabled, isFalse);
    });

    test('rejects invalid coordinates and keeps radius within supported range', () {
      expect(
        () => SafeZone.fromJson(<String, Object?>{
          'latitude': 95,
          'longitude': -80,
        }),
        throwsFormatException,
      );

      final tooSmall = SafeZone.fromJson(<String, Object?>{
        'id': 'tiny',
        'name': 'Tiny',
        'latitude': 43.4723,
        'longitude': -80.5449,
        'radiusMeters': 1,
      });
      final tooLarge = SafeZone.fromJson(<String, Object?>{
        'id': 'large',
        'name': 'Large',
        'latitude': 43.4723,
        'longitude': -80.5449,
        'radiusMeters': 10000,
      });
      expect(tooSmall.radiusMeters, 100);
      expect(tooLarge.radiusMeters, 5000);
    });

    test('adds zones to settings JSON and reads old settings with no zones', () {
      final oldSettings = ProtectionSettings.fromJson(
        <String, Object?>{'deviceDisplayName': 'Laptop'},
      );
      expect(oldSettings.safeZones, isEmpty);
      expect(oldSettings.alertOnAcPowerDisconnect, isTrue);

      const zone = SafeZone(
        id: 'zone_campus',
        name: 'Campus',
        latitude: 43.4723,
        longitude: -80.5449,
        radiusMeters: 600,
      );
      final settings = oldSettings.copyWith(safeZones: const <SafeZone>[zone]);
      final restored = ProtectionSettings.fromJson(settings.toJson());

      expect(restored.safeZones, hasLength(1));
      expect(restored.safeZones.single.name, 'Campus');
      expect(restored.shareLocationOnAlarm, oldSettings.shareLocationOnAlarm);
    });

    test('ignores malformed legacy zone entries without losing other settings', () {
      final settings = ProtectionSettings.fromJson(<String, Object?>{
        'deviceDisplayName': 'Laptop',
        'safeZones': <Object?>[
          <String, Object?>{
            'id': 'invalid',
            'name': 'Invalid',
            'latitude': double.nan,
            'longitude': -80.5449,
          },
          <String, Object?>{
            'id': 'valid',
            'name': 'Valid',
            'latitude': 43.4723,
            'longitude': -80.5449,
            'radiusMeters': 400,
          },
        ],
      });

      expect(settings.deviceDisplayName, 'Laptop');
      expect(settings.safeZones, hasLength(1));
      expect(settings.safeZones.single.name, 'Valid');
    });
  });
}
