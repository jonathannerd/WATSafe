import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

/// Pure-Dart NIST P-256 (`secp256r1` / `prime256v1`) primitives for:
/// - RFC 8292 VAPID `ES256` JWT signing & verification
/// - RFC 8291 Web Push `aes128gcm` ECDH key agreement & payload encryption
class P256Curve {
  const P256Curve._();

  static final BigInt p = BigInt.parse(
    'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
    radix: 16,
  );
  static final BigInt n = BigInt.parse(
    'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
    radix: 16,
  );
  static final BigInt a = p - BigInt.from(3);
  static final BigInt b = BigInt.parse(
    '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
    radix: 16,
  );
  static final BigInt gx = BigInt.parse(
    '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296',
    radix: 16,
  );
  static final BigInt gy = BigInt.parse(
    '4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5',
    radix: 16,
  );

  static final P256AffinePoint generator = P256AffinePoint(gx, gy);

  static BigInt _modP(BigInt v) {
    final r = v % p;
    return r.isNegative ? r + p : r;
  }

  static BigInt _modN(BigInt v) {
    final r = v % n;
    return r.isNegative ? r + n : r;
  }

  /// Validates that `(x, y)` lies on NIST P-256 and is not at infinity.
  static bool isValidPublicPoint(P256AffinePoint point) {
    final x = point.x;
    final y = point.y;
    if (x <= BigInt.zero || x >= p || y <= BigInt.zero || y >= p) {
      return false;
    }
    final lhs = _modP(y * y);
    final x2 = _modP(x * x);
    final x3 = _modP(x2 * x);
    final rhs = _modP(x3 + a * x + b);
    return lhs == rhs;
  }

  /// Decodes a 65-byte uncompressed SEC 1 P-256 public key (`0x04 || X || Y`).
  static P256AffinePoint decodeUncompressedPoint(Uint8List bytes) {
    if (bytes.length != 65 || bytes[0] != 0x04) {
      throw const FormatException(
        'Expected 65-byte uncompressed P-256 public key starting with 0x04.',
      );
    }
    final x = bytesToBigInt(Uint8List.sublistView(bytes, 1, 33));
    final y = bytesToBigInt(Uint8List.sublistView(bytes, 33, 65));
    final pt = P256AffinePoint(x, y);
    if (!isValidPublicPoint(pt)) {
      throw const FormatException('Public key point is not on NIST P-256.');
    }
    return pt;
  }

  /// Encodes an affine point to 65-byte uncompressed SEC 1 format (`0x04 || X || Y`).
  static Uint8List encodeUncompressedPoint(P256AffinePoint point) {
    final out = Uint8List(65);
    out[0] = 0x04;
    out.setRange(1, 33, bigIntToBytes(point.x, 32));
    out.setRange(33, 65, bigIntToBytes(point.y, 32));
    return out;
  }

  /// Generates a cryptographically random P-256 private scalar `1 <= d < n`.
  static BigInt generatePrivateScalar([Random? random]) {
    final rng = random ?? Random.secure();
    while (true) {
      final bytes = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        bytes[i] = rng.nextInt(256);
      }
      final d = bytesToBigInt(bytes);
      if (d >= BigInt.one && d < n) {
        return d;
      }
    }
  }

  /// Computes `k * point` on NIST P-256 and returns the affine result.
  static P256AffinePoint scalarMultiply(BigInt k, P256AffinePoint point) {
    final scalar = _modN(k);
    if (scalar == BigInt.zero) {
      throw ArgumentError('Scalar multiple produced point at infinity.');
    }
    if (!isValidPublicPoint(point)) {
      throw ArgumentError('Base point is not on NIST P-256.');
    }

    var acc = _JacobianPoint.infinity;
    final addend = _JacobianPoint(point.x, point.y, BigInt.one);
    final bitLen = scalar.bitLength;
    for (var i = bitLen - 1; i >= 0; i--) {
      acc = _pointDouble(acc);
      if (((scalar >> i) & BigInt.one) == BigInt.one) {
        acc = _pointAdd(acc, addend);
      }
    }
    return _toAffine(acc);
  }

  static P256AffinePoint publicKeyFromPrivate(BigInt privateScalar) {
    if (privateScalar < BigInt.one || privateScalar >= n) {
      throw RangeError('Invalid P-256 private scalar.');
    }
    return scalarMultiply(privateScalar, generator);
  }

  /// Computes the 32-byte ECDH P-256 shared secret (`X` coordinate of `d * Q`).
  static Uint8List computeEcdhSharedSecret({
    required BigInt localPrivateScalar,
    required P256AffinePoint remotePublicPoint,
  }) {
    final sharedPoint = scalarMultiply(localPrivateScalar, remotePublicPoint);
    return bigIntToBytes(sharedPoint.x, 32);
  }

  /// Signs `messageBytes` with ECDSA P-256 SHA-256 and returns the 64-byte
  /// JWS `ES256` signature (`R[32] || S[32]`).
  static Uint8List signEs256({
    required BigInt privateScalar,
    required List<int> messageBytes,
    Random? random,
  }) {
    final digest = crypto.sha256.convert(messageBytes).bytes;
    final z = bytesToBigInt(Uint8List.fromList(digest));
    final rng = random ?? Random.secure();

    while (true) {
      final k = generatePrivateScalar(rng);
      final kPoint = scalarMultiply(k, generator);
      final r = _modN(kPoint.x);
      if (r == BigInt.zero) {
        continue;
      }
      final kInv = k.modInverse(n);
      var s = _modN(kInv * _modN(z + _modN(r * privateScalar)));
      if (s == BigInt.zero) {
        continue;
      }
      final out = Uint8List(64);
      out.setRange(0, 32, bigIntToBytes(r, 32));
      out.setRange(32, 64, bigIntToBytes(s, 32));
      return out;
    }
  }

  /// Verifies a 64-byte JWS `ES256` signature (`R[32] || S[32]`) over `messageBytes`.
  static bool verifyEs256({
    required P256AffinePoint publicPoint,
    required List<int> messageBytes,
    required Uint8List signatureBytes,
  }) {
    if (signatureBytes.length != 64 || !isValidPublicPoint(publicPoint)) {
      return false;
    }
    final r = bytesToBigInt(Uint8List.sublistView(signatureBytes, 0, 32));
    final s = bytesToBigInt(Uint8List.sublistView(signatureBytes, 32, 64));
    if (r < BigInt.one || r >= n || s < BigInt.one || s >= n) {
      return false;
    }
    final digest = crypto.sha256.convert(messageBytes).bytes;
    final z = bytesToBigInt(Uint8List.fromList(digest));
    final w = s.modInverse(n);
    final u1 = _modN(z * w);
    final u2 = _modN(r * w);

    var jSum = _JacobianPoint.infinity;
    if (u1 != BigInt.zero) {
      final p1 = scalarMultiply(u1, generator);
      jSum = _pointAdd(jSum, _JacobianPoint(p1.x, p1.y, BigInt.one));
    }
    if (u2 != BigInt.zero) {
      final p2 = scalarMultiply(u2, publicPoint);
      jSum = _pointAdd(jSum, _JacobianPoint(p2.x, p2.y, BigInt.one));
    }
    if (jSum.isInfinity) {
      return false;
    }
    final check = _toAffine(jSum);
    return _modN(check.x) == r;
  }

  static _JacobianPoint _pointDouble(_JacobianPoint pt) {
    if (pt.isInfinity || pt.y == BigInt.zero) {
      return _JacobianPoint.infinity;
    }
    final x1 = pt.x;
    final y1 = pt.y;
    final z1 = pt.z;

    final z1Sq = _modP(z1 * z1);
    final m = _modP(BigInt.from(3) * _modP(x1 - z1Sq) * _modP(x1 + z1Sq));
    final y1Sq = _modP(y1 * y1);
    final s = _modP(BigInt.from(4) * x1 * y1Sq);
    final x3 = _modP(m * m - BigInt.two * s);
    final y1Fourth = _modP(y1Sq * y1Sq);
    final y3 = _modP(m * _modP(s - x3) - BigInt.from(8) * y1Fourth);
    final z3 = _modP(BigInt.two * y1 * z1);
    return _JacobianPoint(x3, y3, z3);
  }

  static _JacobianPoint _pointAdd(_JacobianPoint p1, _JacobianPoint p2) {
    if (p1.isInfinity) {
      return p2;
    }
    if (p2.isInfinity) {
      return p1;
    }

    final z1Sq = _modP(p1.z * p1.z);
    final z2Sq = _modP(p2.z * p2.z);
    final u1 = _modP(p1.x * z2Sq);
    final u2 = _modP(p2.x * z1Sq);
    final s1 = _modP(p1.y * _modP(p2.z * z2Sq));
    final s2 = _modP(p2.y * _modP(p1.z * z1Sq));

    if (u1 == u2) {
      if (s1 != s2) {
        return _JacobianPoint.infinity;
      }
      return _pointDouble(p1);
    }

    final h = _modP(u2 - u1);
    final r = _modP(s2 - s1);
    final hSq = _modP(h * h);
    final hCu = _modP(h * hSq);
    final u1hSq = _modP(u1 * hSq);

    final x3 = _modP(r * r - hCu - BigInt.two * u1hSq);
    final y3 = _modP(r * _modP(u1hSq - x3) - s1 * hCu);
    final z3 = _modP(h * _modP(p1.z * p2.z));
    return _JacobianPoint(x3, y3, z3);
  }

  static P256AffinePoint _toAffine(_JacobianPoint pt) {
    if (pt.isInfinity) {
      throw StateError('Cannot convert point at infinity to affine.');
    }
    final zInv = pt.z.modInverse(p);
    final zInvSq = _modP(zInv * zInv);
    final zInvCu = _modP(zInvSq * zInv);
    return P256AffinePoint(_modP(pt.x * zInvSq), _modP(pt.y * zInvCu));
  }

  static BigInt bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  static Uint8List bigIntToBytes(BigInt value, int length) {
    final out = Uint8List(length);
    var temp = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (temp & BigInt.from(0xff)).toInt();
      temp = temp >> 8;
    }
    return out;
  }
}

class P256AffinePoint {
  const P256AffinePoint(this.x, this.y);
  final BigInt x;
  final BigInt y;
}

class _JacobianPoint {
  const _JacobianPoint(this.x, this.y, this.z);
  static final _JacobianPoint infinity = _JacobianPoint(
    BigInt.zero,
    BigInt.one,
    BigInt.zero,
  );
  final BigInt x;
  final BigInt y;
  final BigInt z;

  bool get isInfinity => z == BigInt.zero;
}

/// Base64url helpers (RFC 7515 / RFC 8291 / RFC 8292, unpadded).
String base64UrlNoPadEncode(List<int> bytes) {
  return base64UrlEncode(bytes).replaceAll('=', '');
}

Uint8List base64FlexibleDecode(String encoded) {
  var normalized = encoded
      .trim()
      .replaceAll('-', '+')
      .replaceAll('_', '/')
      .replaceAll(RegExp(r'\s+'), '');
  final mod4 = normalized.length % 4;
  if (mod4 == 2) {
    normalized += '==';
  } else if (mod4 == 3) {
    normalized += '=';
  } else if (mod4 == 1) {
    throw const FormatException('Invalid base64url string length.');
  }
  return Uint8List.fromList(base64Decode(normalized));
}

/// Server VAPID keypair (RFC 8292).
///
/// Security invariant: [privateKeyBase64Url] is strictly server-private and is
/// never serialized into API responses or logs.
class VapidKeyPair {
  VapidKeyPair._({
    required this.privateScalar,
    required this.publicPoint,
    required this.publicKeyBytes,
  });

  final BigInt privateScalar;
  final P256AffinePoint publicPoint;
  final Uint8List publicKeyBytes;

  String get publicKeyBase64Url => base64UrlNoPadEncode(publicKeyBytes);

  String get privateKeyBase64Url =>
      base64UrlNoPadEncode(P256Curve.bigIntToBytes(privateScalar, 32));

  factory VapidKeyPair.generate([Random? random]) {
    final d = P256Curve.generatePrivateScalar(random);
    final pub = P256Curve.publicKeyFromPrivate(d);
    return VapidKeyPair._(
      privateScalar: d,
      publicPoint: pub,
      publicKeyBytes: P256Curve.encodeUncompressedPoint(pub),
    );
  }

  factory VapidKeyPair.fromPrivateKeyBytes(Uint8List privateBytes) {
    if (privateBytes.length != 32) {
      throw const FormatException('VAPID private key must be 32 bytes.');
    }
    final d = P256Curve.bytesToBigInt(privateBytes);
    final pub = P256Curve.publicKeyFromPrivate(d);
    return VapidKeyPair._(
      privateScalar: d,
      publicPoint: pub,
      publicKeyBytes: P256Curve.encodeUncompressedPoint(pub),
    );
  }

  factory VapidKeyPair.fromBase64Url({
    required String privateKeyBase64Url,
    String? publicKeyBase64Url,
  }) {
    final privBytes = base64FlexibleDecode(privateKeyBase64Url);
    final pair = VapidKeyPair.fromPrivateKeyBytes(privBytes);
    if (publicKeyBase64Url != null && publicKeyBase64Url.trim().isNotEmpty) {
      final expectedPub = base64FlexibleDecode(publicKeyBase64Url);
      if (expectedPub.length != 65 ||
          base64UrlNoPadEncode(expectedPub) != pair.publicKeyBase64Url) {
        throw const FormatException(
          'VAPID_PUBLIC_KEY does not match VAPID_PRIVATE_KEY.',
        );
      }
    }
    return pair;
  }

  static File resolveDefaultVapidKeyFile([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    final explicitDir = (env['WATSAFE_DATA_DIR'] ?? '').trim();
    if (explicitDir.isNotEmpty) {
      return File('$explicitDir/vapid_keys.json');
    }
    final legacyFile = File('.watsafe-runtime/vapid_keys.json');
    final home = (env['HOME'] ?? env['USERPROFILE'] ?? '').trim();
    if (home.isNotEmpty) {
      final durableFile = File('$home/.watsafe/relay/vapid_keys.json');
      if (!durableFile.existsSync() && legacyFile.existsSync()) {
        try {
          durableFile.parent.createSync(recursive: true);
          legacyFile.copySync(durableFile.path);
          if (!Platform.isWindows) {
            Process.runSync('chmod', <String>['600', durableFile.path]);
          }
        } catch (_) {
          return legacyFile;
        }
      }
      return durableFile;
    }
    return legacyFile;
  }

  /// Loads VAPID keys from `VAPID_PRIVATE_KEY` (+ optional `VAPID_PUBLIC_KEY`)
  /// in [environment], or loads/creates a persistent local keypair in [keyFile]
  /// when [persistToDisk] is true.
  static VapidKeyPair loadOrCreate({
    Map<String, String>? environment,
    File? keyFile,
    bool persistToDisk = false,
  }) {
    final env = environment ?? Platform.environment;
    final envPriv = (env['VAPID_PRIVATE_KEY'] ?? '').trim();
    final envPub = (env['VAPID_PUBLIC_KEY'] ?? '').trim();

    if (envPriv.isNotEmpty) {
      return VapidKeyPair.fromBase64Url(
        privateKeyBase64Url: envPriv,
        publicKeyBase64Url: envPub.isEmpty ? null : envPub,
      );
    }

    final targetFile = keyFile ?? resolveDefaultVapidKeyFile(env);
    if (persistToDisk && targetFile.existsSync()) {
      try {
        final decoded = jsonDecode(targetFile.readAsStringSync());
        if (decoded is Map && decoded['privateKey'] is String) {
          return VapidKeyPair.fromBase64Url(
            privateKeyBase64Url: decoded['privateKey'] as String,
            publicKeyBase64Url: decoded['publicKey'] as String?,
          );
        }
      } catch (_) {
        // Regenerate if corrupted
      }
    }

    final generated = VapidKeyPair.generate();
    if (persistToDisk) {
      try {
        targetFile.parent.createSync(recursive: true);
        targetFile.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(<String, String>{
            'publicKey': generated.publicKeyBase64Url,
            'privateKey': generated.privateKeyBase64Url,
            'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
          }),
          flush: true,
        );
        if (!Platform.isWindows) {
          Process.runSync('chmod', <String>['600', targetFile.path]);
        }
      } catch (_) {
        // Non-fatal if filesystem is read-only
      }
    }
    return generated;
  }

  static const String defaultSubject = 'mailto:alerts@watsafe.app';

  static const Set<String> _reservedNonPublicTlds = <String>{
    'local',
    'localhost',
    'internal',
    'test',
    'invalid',
    'lan',
    'home',
    'arpa',
    'corp',
  };

  static bool _isPublicRoutableDomain(String rawHost) {
    final host = rawHost.trim().toLowerCase();
    if (host.isEmpty || host.contains('[') || host.contains(']')) {
      return false;
    }
    if (InternetAddress.tryParse(host) != null) {
      return false;
    }
    final labels = host.split('.');
    if (labels.length < 2) {
      return false;
    }
    for (final label in labels) {
      if (label.isEmpty ||
          label.startsWith('-') ||
          label.endsWith('-') ||
          !RegExp(r'^[a-z0-9-]+$').hasMatch(label)) {
        return false;
      }
    }
    final tld = labels.last;
    if (tld.length < 2 || RegExp(r'^\d+$').hasMatch(tld)) {
      return false;
    }
    return !_reservedNonPublicTlds.contains(tld);
  }

  /// Returns `true` iff [candidate] is an RFC 8292 `mailto:` or `https://` URI
  /// with a public routable domain accepted by Apple Web Push (`web.push.apple.com`)
  /// and Google FCM (rejecting `.local`, `.localhost`, `.internal`, IP literals, etc.).
  static bool isValidPublicSubject(String? candidate) {
    if (candidate == null) {
      return false;
    }
    final trimmed = candidate.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    if (trimmed.toLowerCase().startsWith('mailto:')) {
      final addr = trimmed.substring('mailto:'.length).trim();
      final atIdx = addr.indexOf('@');
      if (atIdx <= 0 || atIdx != addr.lastIndexOf('@')) {
        return false;
      }
      final localPart = addr.substring(0, atIdx);
      final domainPart = addr.substring(atIdx + 1);
      if (localPart.isEmpty || localPart.contains(' ')) {
        return false;
      }
      return _isPublicRoutableDomain(domainPart);
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        !uri.hasAuthority) {
      return false;
    }
    if (uri.userInfo.isNotEmpty) {
      return false;
    }
    return _isPublicRoutableDomain(uri.host);
  }

  /// Normalizes [rawSubject] to a valid RFC 8292 VAPID `sub` claim.
  ///
  /// Apple Web Push (`web.push.apple.com`) rejects `.local` / non-public domains
  /// with `HTTP 403 {"reason":"BadJwtToken"}`. When [rawSubject] is empty or uses
  /// a non-public domain, falls back to [publicHttpsOrigin] (if valid `https://`)
  /// or [defaultSubject].
  static String normalizeSubject(
    String? rawSubject, {
    String? publicHttpsOrigin,
  }) {
    final trimmed = (rawSubject ?? '').trim();
    if (isValidPublicSubject(trimmed)) {
      return trimmed;
    }
    final fallbackOrigin = (publicHttpsOrigin ?? '').trim();
    if (isValidPublicSubject(fallbackOrigin)) {
      final parsed = Uri.parse(fallbackOrigin);
      return '${parsed.scheme.toLowerCase()}://${parsed.authority.toLowerCase()}';
    }
    return defaultSubject;
  }

  /// Builds an RFC 8292 VAPID `ES256` JWT and `Authorization` header value for
  /// pushing to [endpoint].
  ({String jwt, String authorizationHeader, String cryptoKeyHeader})
  buildVapidHeaders({
    required Uri endpoint,
    String subject = defaultSubject,
    DateTime? nowUtc,
    Duration validity = const Duration(hours: 12),
    Random? random,
  }) {
    final normalizedSub = normalizeSubject(subject);
    final origin = '${endpoint.scheme}://${endpoint.authority}';
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final exp =
        now.add(validity).millisecondsSinceEpoch ~/
        Duration.millisecondsPerSecond;

    final headerJson = jsonEncode(const <String, String>{
      'typ': 'JWT',
      'alg': 'ES256',
    });
    final payloadJson = jsonEncode(<String, Object>{
      'aud': origin,
      'exp': exp,
      'sub': normalizedSub,
    });

    final signingInput =
        '${base64UrlNoPadEncode(utf8.encode(headerJson))}.'
        '${base64UrlNoPadEncode(utf8.encode(payloadJson))}';
    final sig = P256Curve.signEs256(
      privateScalar: privateScalar,
      messageBytes: ascii.encode(signingInput),
      random: random,
    );
    final jwt = '$signingInput.${base64UrlNoPadEncode(sig)}';
    final pub = publicKeyBase64Url;
    return (
      jwt: jwt,
      authorizationHeader: 'vapid t=$jwt, k=$pub',
      cryptoKeyHeader: 'p256ecdsa=$pub',
    );
  }
}

/// Validated browser/PWA `PushSubscription` (`endpoint`, `p256dh`, `auth`).
class WebPushSubscriptionData {
  const WebPushSubscriptionData({
    required this.endpoint,
    required this.p256dhBase64Url,
    required this.authBase64Url,
  });

  final Uri endpoint;
  final String p256dhBase64Url;
  final String authBase64Url;

  /// Validates that [endpoint] uses HTTPS (or loopback HTTP for automated tests),
  /// [p256dh] is a valid 65-byte NIST P-256 uncompressed public key, and [auth]
  /// is at least 16 bytes.
  factory WebPushSubscriptionData.validate({
    required String endpointRaw,
    required String p256dhRaw,
    required String authRaw,
  }) {
    final uri = Uri.tryParse(endpointRaw.trim());
    if (uri == null || !uri.hasAuthority) {
      throw const FormatException('Push subscription endpoint is invalid.');
    }
    final isSecureScheme = uri.scheme == 'https';
    final isLoopbackTest =
        uri.scheme == 'http' &&
        (uri.host == '127.0.0.1' || uri.host == 'localhost');
    if (!isSecureScheme && !isLoopbackTest) {
      throw const FormatException(
        'Push subscription endpoint must use https://.',
      );
    }

    final pubBytes = base64FlexibleDecode(p256dhRaw);
    P256Curve.decodeUncompressedPoint(pubBytes);

    final authBytes = base64FlexibleDecode(authRaw);
    if (authBytes.length < 16) {
      throw const FormatException(
        'Push subscription auth secret must be at least 16 bytes.',
      );
    }

    return WebPushSubscriptionData(
      endpoint: uri,
      p256dhBase64Url: base64UrlNoPadEncode(pubBytes),
      authBase64Url: base64UrlNoPadEncode(authBytes),
    );
  }
}

/// RFC 8291 (`aes128gcm`) Web Push payload encryption & test decryption.
class WebPushCrypto {
  const WebPushCrypto._();

  static final AesGcm _aes128Gcm = AesGcm.with128bits();

  static Uint8List _hmacSha256(List<int> key, List<int> data) {
    return Uint8List.fromList(
      crypto.Hmac(crypto.sha256, key).convert(data).bytes,
    );
  }

  /// Encrypts [plaintext] using RFC 8291 (`Content-Encoding: aes128gcm`).
  static Future<Uint8List> encryptAes128Gcm({
    required List<int> plaintext,
    required String clientP256dhBase64Url,
    required String clientAuthBase64Url,
    Uint8List? saltOverride,
    VapidKeyPair? ephemeralServerKeyOverride,
    Random? random,
  }) async {
    final rng = random ?? Random.secure();
    final uaPublicBytes = base64FlexibleDecode(clientP256dhBase64Url);
    final uaPublicPoint = P256Curve.decodeUncompressedPoint(uaPublicBytes);
    final authSecret = base64FlexibleDecode(clientAuthBase64Url);
    if (authSecret.length < 16) {
      throw const FormatException('Client auth secret must be >= 16 bytes.');
    }

    final serverEphemeral =
        ephemeralServerKeyOverride ?? VapidKeyPair.generate(rng);
    final asPublicBytes = serverEphemeral.publicKeyBytes;

    final salt =
        saltOverride ??
        Uint8List.fromList(List<int>.generate(16, (_) => rng.nextInt(256)));
    if (salt.length != 16) {
      throw ArgumentError('RFC 8291 salt must be 16 bytes.');
    }

    final ecdhSecret = P256Curve.computeEcdhSharedSecret(
      localPrivateScalar: serverEphemeral.privateScalar,
      remotePublicPoint: uaPublicPoint,
    );

    final derived = _deriveCekAndNonce(
      ecdhSecret: ecdhSecret,
      authSecret: authSecret,
      uaPublicBytes: uaPublicBytes,
      asPublicBytes: asPublicBytes,
      salt: salt,
    );

    // RFC 8188 §2: final record delimiter 0x02 with zero padding bytes.
    final paddedPlaintext = Uint8List(plaintext.length + 1);
    paddedPlaintext.setRange(0, plaintext.length, plaintext);
    paddedPlaintext[plaintext.length] = 0x02;

    final secretBox = await _aes128Gcm.encrypt(
      paddedPlaintext,
      secretKey: SecretKey(derived.cek),
      nonce: derived.nonce,
    );

    // RFC 8188 §2.1 header: salt(16) || rs(4, 4096) || idlen(1, 65) || keyid(65)
    const recordSize = 4096;
    final headerLen = 16 + 4 + 1 + asPublicBytes.length;
    final body = Uint8List(
      headerLen + secretBox.cipherText.length + secretBox.mac.bytes.length,
    );
    body.setRange(0, 16, salt);
    body[16] = (recordSize >> 24) & 0xff;
    body[17] = (recordSize >> 16) & 0xff;
    body[18] = (recordSize >> 8) & 0xff;
    body[19] = recordSize & 0xff;
    body[20] = asPublicBytes.length;
    body.setRange(21, 21 + asPublicBytes.length, asPublicBytes);

    final ctOffset = headerLen;
    body.setRange(
      ctOffset,
      ctOffset + secretBox.cipherText.length,
      secretBox.cipherText,
    );
    body.setRange(
      ctOffset + secretBox.cipherText.length,
      body.length,
      secretBox.mac.bytes,
    );
    return body;
  }

  /// Decrypts an RFC 8291 `aes128gcm` Web Push payload (used in automated E2E
  /// verification to prove real browser/iOS push compatibility).
  static Future<Uint8List> decryptAes128Gcm({
    required Uint8List encryptedBody,
    required VapidKeyPair clientKeyPair,
    required Uint8List clientAuthSecret,
  }) async {
    if (encryptedBody.length < 21 + 65 + 17) {
      throw const FormatException('Encrypted aes128gcm body is truncated.');
    }
    final salt = Uint8List.sublistView(encryptedBody, 0, 16);
    final idLen = encryptedBody[20];
    if (idLen != 65 || encryptedBody.length < 21 + idLen + 17) {
      throw const FormatException(
        'Unsupported keyid length in aes128gcm header.',
      );
    }
    final asPublicBytes = Uint8List.sublistView(encryptedBody, 21, 21 + idLen);
    final asPublicPoint = P256Curve.decodeUncompressedPoint(asPublicBytes);
    final cipherAndTag = Uint8List.sublistView(encryptedBody, 21 + idLen);

    final ecdhSecret = P256Curve.computeEcdhSharedSecret(
      localPrivateScalar: clientKeyPair.privateScalar,
      remotePublicPoint: asPublicPoint,
    );

    final derived = _deriveCekAndNonce(
      ecdhSecret: ecdhSecret,
      authSecret: clientAuthSecret,
      uaPublicBytes: clientKeyPair.publicKeyBytes,
      asPublicBytes: asPublicBytes,
      salt: salt,
    );

    final cipherText = Uint8List.sublistView(
      cipherAndTag,
      0,
      cipherAndTag.length - 16,
    );
    final tag = Uint8List.sublistView(cipherAndTag, cipherAndTag.length - 16);

    final paddedPlaintext = await _aes128Gcm.decrypt(
      SecretBox(cipherText, nonce: derived.nonce, mac: Mac(tag)),
      secretKey: SecretKey(derived.cek),
    );

    // Strip trailing 0x00 padding and 0x02 final-record delimiter (RFC 8188 §2).
    var end = paddedPlaintext.length - 1;
    while (end >= 0 && paddedPlaintext[end] == 0x00) {
      end--;
    }
    if (end < 0 || paddedPlaintext[end] != 0x02) {
      throw const FormatException('Missing RFC 8188 0x02 record delimiter.');
    }
    return Uint8List.fromList(paddedPlaintext.sublist(0, end));
  }

  static ({Uint8List cek, Uint8List nonce}) _deriveCekAndNonce({
    required Uint8List ecdhSecret,
    required Uint8List authSecret,
    required Uint8List uaPublicBytes,
    required Uint8List asPublicBytes,
    required Uint8List salt,
  }) {
    // RFC 8291 §3.3:
    // PRK_key = HMAC-SHA-256(auth_secret, ecdh_secret)
    // key_info = "WebPush: info" || 0x00 || ua_public || as_public
    // IKM = HMAC-SHA-256(PRK_key, key_info || 0x01)
    final prkKey = _hmacSha256(authSecret, ecdhSecret);
    final prefix = ascii.encode('WebPush: info');
    final keyInfoAndOne = Uint8List(
      prefix.length + 1 + uaPublicBytes.length + asPublicBytes.length + 1,
    );
    var offset = 0;
    keyInfoAndOne.setRange(offset, offset + prefix.length, prefix);
    offset += prefix.length;
    keyInfoAndOne[offset++] = 0x00;
    keyInfoAndOne.setRange(
      offset,
      offset + uaPublicBytes.length,
      uaPublicBytes,
    );
    offset += uaPublicBytes.length;
    keyInfoAndOne.setRange(
      offset,
      offset + asPublicBytes.length,
      asPublicBytes,
    );
    offset += asPublicBytes.length;
    keyInfoAndOne[offset] = 0x01;

    final ikm = _hmacSha256(prkKey, keyInfoAndOne);

    // RFC 8291 §3.4 / RFC 8188 §2.2 & §2.3:
    final prk = _hmacSha256(salt, ikm);
    final cekInfo = Uint8List.fromList(<int>[
      ...ascii.encode('Content-Encoding: aes128gcm'),
      0x00,
      0x01,
    ]);
    final nonceInfo = Uint8List.fromList(<int>[
      ...ascii.encode('Content-Encoding: nonce'),
      0x00,
      0x01,
    ]);

    final cek = Uint8List.fromList(_hmacSha256(prk, cekInfo).sublist(0, 16));
    final nonce = Uint8List.fromList(
      _hmacSha256(prk, nonceInfo).sublist(0, 12),
    );
    return (cek: cek, nonce: nonce);
  }
}

/// Result of dispatching an RFC 8030 + RFC 8291 + RFC 8292 Web Push request.
///
/// Note: [delivered] means the push service (`web.push.apple.com` / FCM)
/// accepted the encrypted payload (`HTTP 2xx`). Confirmed phone receipt is
/// tracked separately when the phone's Service Worker or app acknowledges the event.
class WebPushDeliveryResult {
  const WebPushDeliveryResult({
    required this.delivered,
    required this.statusCode,
    this.subscriptionExpired = false,
    this.vapidMismatch = false,
    this.providerReason,
    this.endpointHost,
    this.errorDetail,
  });

  final bool delivered;
  final int statusCode;
  final bool subscriptionExpired;
  final bool vapidMismatch;
  final String? providerReason;
  final String? endpointHost;
  final String? errorDetail;
}

/// Sends encrypted Web Push notifications directly to Apple (`web.push.apple.com`),
/// Google FCM (`fcm.googleapis.com`), Mozilla Autopush, or standard RFC 8030 endpoints.
class DirectWebPushSender {
  DirectWebPushSender({
    required this.vapidKeyPair,
    String vapidSubject = VapidKeyPair.defaultSubject,
    String? publicHttpsOrigin,
    this.timeout = const Duration(seconds: 6),
    this.logFailuresToStderr = true,
  }) : vapidSubject = VapidKeyPair.normalizeSubject(
         vapidSubject,
         publicHttpsOrigin: publicHttpsOrigin,
       );

  final VapidKeyPair vapidKeyPair;
  final String vapidSubject;
  final Duration timeout;
  final bool logFailuresToStderr;

  static const Set<String> _expiredProviderReasons = <String>{
    'BadWebPushToken',
    'Unregistered',
    'ExpiredSubscription',
    'DeviceTokenNotForTopic',
    'VapidPkHashMismatch',
  };

  static String derivePushTopic(String incidentId) {
    final digest = crypto.sha256.convert(utf8.encode(incidentId)).bytes;
    return base64UrlNoPadEncode(
      digest.sublist(0, 18),
    ); // 24 base64url chars (<= 32)
  }

  /// Strips any URLs, paths, or long token-like segments so logs and status
  /// fields never expose subscription endpoints or secrets.
  static String sanitizeDiagnosticText(String raw) {
    var cleaned = raw.replaceAll(RegExp(r'https?://\S+'), '<redacted-url>');
    cleaned = cleaned.replaceAll(
      RegExp(r'[A-Za-z0-9_-]{40,}'),
      '<redacted-token>',
    );
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length > 140) {
      cleaned = '${cleaned.substring(0, 140)}...';
    }
    return cleaned;
  }

  static String? _extractProviderReason(String rawBody, int statusCode) {
    final trimmed = rawBody.trim();
    if (trimmed.isNotEmpty) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          for (final key in const <String>['reason', 'error', 'message']) {
            final val = decoded[key];
            if (val is String && val.trim().isNotEmpty) {
              return sanitizeDiagnosticText(val);
            }
          }
        }
      } catch (_) {
        return sanitizeDiagnosticText(trimmed);
      }
    }
    if (statusCode > 0) {
      return 'HTTP_$statusCode';
    }
    return null;
  }

  static Future<String> _readBoundedUtf8(
    HttpClientResponse response, {
    int maxBytes = 2048,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      final remaining = maxBytes - builder.length;
      if (remaining > 0) {
        if (chunk.length <= remaining) {
          builder.add(chunk);
        } else {
          builder.add(chunk.sublist(0, remaining));
        }
      }
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<WebPushDeliveryResult> sendJsonNotification({
    required WebPushSubscriptionData subscription,
    required Map<String, Object?> payload,
    String? incidentId,
    int ttlSeconds = 86400,
  }) async {
    final host = subscription.endpoint.host;
    final plaintext = utf8.encode(jsonEncode(payload));
    final encryptedBody = await WebPushCrypto.encryptAes128Gcm(
      plaintext: plaintext,
      clientP256dhBase64Url: subscription.p256dhBase64Url,
      clientAuthBase64Url: subscription.authBase64Url,
    );
    final vapid = vapidKeyPair.buildVapidHeaders(
      endpoint: subscription.endpoint,
      subject: vapidSubject,
    );

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.postUrl(subscription.endpoint);
      req.headers.set(
        HttpHeaders.authorizationHeader,
        vapid.authorizationHeader,
      );
      req.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/octet-stream',
      );
      req.headers.set(HttpHeaders.contentEncodingHeader, 'aes128gcm');
      req.headers.set('TTL', '$ttlSeconds');
      req.headers.set('Urgency', 'high');
      if (incidentId != null && incidentId.trim().isNotEmpty) {
        req.headers.set('Topic', derivePushTopic(incidentId.trim()));
      }
      req.contentLength = encryptedBody.length;
      req.add(encryptedBody);

      final res = await req.close().timeout(timeout);
      final code = res.statusCode;
      final accepted = code >= 200 && code < 300;
      String? reason;
      if (accepted) {
        await res.drain<void>();
      } else {
        final rawErrorBody = await _readBoundedUtf8(res);
        reason = _extractProviderReason(rawErrorBody, code);
      }

      final vapidMismatch = reason == 'VapidPkHashMismatch';
      final expired =
          code == HttpStatus.notFound ||
          code == HttpStatus.gone ||
          (reason != null && _expiredProviderReasons.contains(reason));

      if (!accepted && logFailuresToStderr) {
        stderr.writeln(
          '[WATSafe WebPush] Rejected by push gateway host=$host '
          'status=$code reason=${reason ?? "unknown"} '
          'expired=$expired incidentId=${incidentId ?? "none"}',
        );
      }

      return WebPushDeliveryResult(
        delivered: accepted,
        statusCode: code,
        subscriptionExpired: expired,
        vapidMismatch: vapidMismatch,
        providerReason: reason,
        endpointHost: host,
        errorDetail: accepted ? null : reason,
      );
    } catch (error) {
      final safeErr = sanitizeDiagnosticText('$error');
      if (logFailuresToStderr) {
        stderr.writeln(
          '[WATSafe WebPush] Network failure host=$host '
          'reason=$safeErr incidentId=${incidentId ?? "none"}',
        );
      }
      return WebPushDeliveryResult(
        delivered: false,
        statusCode: 0,
        providerReason: 'NETWORK_ERROR',
        endpointHost: host,
        errorDetail: safeErr,
      );
    } finally {
      client.close(force: true);
    }
  }
}
