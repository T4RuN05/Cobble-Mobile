import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/xopp_document.dart';

class XoppPainter extends CustomPainter {
  final XoppPage page;
  final ui.Image? pdfImage;

  XoppPainter({required this.page, this.pdfImage});

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw PDF Background (if available)
    if (pdfImage != null) {
      final src = Rect.fromLTWH(0, 0, pdfImage!.width.toDouble(), pdfImage!.height.toDouble());
      final dst = Rect.fromLTWH(0, 0, size.width, size.height);
      canvas.drawImageRect(pdfImage!, src, dst, Paint());
    } else {
      // Draw Solid Background
      final bg = page.background;
      if (bg is SolidBackground) {
        canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), Paint()..color = bg.color);
        
        final linePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0;

        if (bg.style == 'lined' || bg.style == 'ruled') {
          linePaint.color = const Color(0x330000FF); // Light blue lines
          const spacing = 24.0;
          for (var y = spacing; y < size.height; y += spacing) {
            canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
          }
          if (bg.style == 'lined') {
            linePaint.color = const Color(0x66FF0000); // Red margin
            canvas.drawLine(const Offset(72.0, 0), Offset(72.0, size.height), linePaint);
          }
        } else if (bg.style == 'graph') {
          linePaint.color = const Color(0x330000FF);
          const spacing = 14.2;
          for (var y = spacing; y < size.height; y += spacing) {
            canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
          }
          for (var x = spacing; x < size.width; x += spacing) {
            canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
          }
        }
      }
    }

    // 2. Draw the pre-rasterized high-res image texture
    if (page.rasterizedStrokes != null) {
      // The image was scaled up by renderScale during generation, 
      // so we map it back to the exact page layout dimensions.
      final srcRect = Rect.fromLTWH(0, 0, page.rasterizedStrokes!.width.toDouble(), page.rasterizedStrokes!.height.toDouble());
      final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
      canvas.drawImageRect(page.rasterizedStrokes!, srcRect, dstRect, Paint());
    }
  }

  @override
  bool shouldRepaint(covariant XoppPainter oldDelegate) {
    return oldDelegate.page != page || oldDelegate.pdfImage != pdfImage;
  }
}
