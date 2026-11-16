import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// Renders a real ISO/IEC 18004 camera-scannable QR code with a 4-module quiet
/// zone so iOS and Android phone cameras recognize it immediately.
class QrCodeWidget extends StatelessWidget {
  const QrCodeWidget({
    super.key,
    required this.data,
    this.size = 216,
    this.backgroundColor = Colors.white,
    this.foregroundColor = const Color(0xFF111316),
  });

  final String data;
  final double size;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final qrCode = QrCode(
      payload: QrPayload.fromString(data),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    );
    final qrImage = QrImage(qrCode);

    return Semantics(
      label: 'Pairing QR code',
      child: Container(
        key: const Key('pairing_qr_matrix'),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(14),
        ),
        child: CustomPaint(
          size: Size.square(size),
          painter: _RealQrPainter(
            qrImage: qrImage,
            foregroundColor: foregroundColor,
          ),
        ),
      ),
    );
  }
}

class _RealQrPainter extends CustomPainter {
  _RealQrPainter({
    required this.qrImage,
    required this.foregroundColor,
  });

  final QrImage qrImage;
  final Color foregroundColor;

  @override
  void paint(Canvas canvas, Size size) {
    const quietZoneModules = 4;
    final moduleCount = qrImage.moduleCount;
    final totalModules = moduleCount + quietZoneModules * 2;
    final cellSize = size.width / totalModules;

    final darkPaint = Paint()
      ..color = foregroundColor
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;

    for (var row = 0; row < moduleCount; row++) {
      for (var col = 0; col < moduleCount; col++) {
        if (qrImage.isDark(row, col)) {
          final left = (col + quietZoneModules) * cellSize;
          final top = (row + quietZoneModules) * cellSize;
          // Slight 0.35px overlap avoids hairline subpixel seams on HiDPI displays.
          canvas.drawRect(
            Rect.fromLTWH(left, top, cellSize + 0.35, cellSize + 0.35),
            darkPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RealQrPainter oldDelegate) {
    return oldDelegate.qrImage != qrImage ||
        oldDelegate.foregroundColor != foregroundColor;
  }
}
