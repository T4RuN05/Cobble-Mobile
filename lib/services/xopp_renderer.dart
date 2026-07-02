import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/xopp_document.dart';
import 'storage_service.dart';

class XoppRenderer {
  /// Render Scale defines the resolution of the cached bitmap.
  /// A scale of 2.0 provides Retina/HD crispness while zooming, without eating too much RAM.
  static const double renderScale = 2.0;

  /// Iterates through the document and pre-renders the vector paths of each page 
  /// into a flat, static [ui.Image] texture on the GPU. Uses local disk caching.
  static Future<void> rasterizeDocument(
    XoppDocument document, 
    String filename, 
    DateTime documentLastModified
  ) async {
    final dirPath = await StorageService.getStorageDirectory();
    final cacheDir = Directory('$dirPath/cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    for (int i = 0; i < document.pages.length; i++) {
      final page = document.pages[i];
      if (page.rasterizedStrokes != null) continue; // Already rendered in memory
      
      final cacheFile = File('${cacheDir.path}/${filename}_page_$i.png');
      bool isCacheValid = false;

      if (await cacheFile.exists()) {
        final cacheModified = await cacheFile.lastModified();
        // If cache is newer or same age as document, use it
        if (!cacheModified.isBefore(documentLastModified)) {
          isCacheValid = true;
        }
      }

      if (isCacheValid) {
        // Cache Hit: Load PNG directly from disk
        final bytes = await cacheFile.readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        page.rasterizedStrokes = frame.image;
      } else {
        // Cache Miss: Bake vectors into ui.Image
        final image = await _rasterizePageStrokes(page);
        page.rasterizedStrokes = image;
        
        // Save to disk asynchronously so we don't block the UI
        _saveImageToDisk(image, cacheFile);
      }
    }
  }

  static Future<void> _saveImageToDisk(ui.Image image, File cacheFile) async {
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        await cacheFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      }
    } catch (e) {
      debugPrint("Failed to save cache file: $e");
    }
  }

  static Future<ui.Image> _rasterizePageStrokes(XoppPage page) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    
    // Scale the canvas up so the resulting image is high-resolution
    canvas.scale(renderScale, renderScale);

    for (final layer in page.layers) {
      for (final element in layer.elements) {
        if (element is XoppStroke) {
          _drawStroke(canvas, element);
        } else if (element is XoppImageElement) {
          if (element.decodedImage == null) {
            final codec = await ui.instantiateImageCodec(element.imageBytes);
            final frame = await codec.getNextFrame();
            element.decodedImage = frame.image;
          }
          final img = element.decodedImage!;
          final src = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
          final dst = Rect.fromLTRB(element.left, element.top, element.right, element.bottom);
          canvas.drawImageRect(img, src, dst, Paint());
        }
      }
    }

    final picture = recorder.endRecording();
    
    // Convert the vector picture into a flat pixel bitmap asynchronously.
    // The physical pixel dimensions are the page dimensions multiplied by the scale.
    final image = await picture.toImage(
      (page.width * renderScale).ceil(),
      (page.height * renderScale).ceil(),
    );
    
    return image;
  }

  static void _drawStroke(Canvas canvas, XoppStroke stroke) {
    if (stroke.points.isEmpty) return;

    final paint = Paint()
      ..color = stroke.color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (stroke.tool == 'highlighter') {
      paint.color = stroke.color.withOpacity(0.5);
      paint.blendMode = BlendMode.multiply;
    }

    if (stroke.widths.length == 1) {
      // Constant pressure
      paint.strokeWidth = stroke.widths.first;
      final path = Path();
      path.moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (var i = 1; i < stroke.points.length; i++) {
        path.lineTo(stroke.points[i].dx, stroke.points[i].dy);
      }
      canvas.drawPath(path, paint);
    } else {
      // Variable pressure (smooth pressure)
      for (var i = 1; i < stroke.points.length; i++) {
        paint.strokeWidth = stroke.widths.length > i ? stroke.widths[i] : stroke.widths.last;
        final path = Path();
        path.moveTo(stroke.points[i - 1].dx, stroke.points[i - 1].dy);
        path.lineTo(stroke.points[i].dx, stroke.points[i].dy);
        canvas.drawPath(path, paint);
      }
    }
  }
}
