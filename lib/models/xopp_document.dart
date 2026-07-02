import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';

class XoppDocument {
  final List<XoppPage> pages;

  XoppDocument({required this.pages});
}

class XoppPage {
  final double width;
  final double height;
  final XoppBackground background;
  final List<XoppLayer> layers;
  
  // The statically baked texture of all strokes on this page
  ui.Image? rasterizedStrokes;

  XoppPage({
    required this.width,
    required this.height,
    required this.background,
    required this.layers,
  });
}

abstract class XoppBackground {
  final String type;
  XoppBackground(this.type);
}

class SolidBackground extends XoppBackground {
  final Color color;
  final String style;

  SolidBackground({required this.color, required this.style}) : super('solid');
}

class PdfBackground extends XoppBackground {
  final String filename;
  final int pageNo;

  PdfBackground({required this.filename, required this.pageNo}) : super('pdf');
}

class XoppLayer {
  final List<XoppElement> elements;

  XoppLayer({required this.elements});
}

abstract class XoppElement {}

class XoppStroke extends XoppElement {
  final String tool;
  final Color color;
  final List<double> widths;
  final List<Offset> points;

  XoppStroke({
    required this.tool,
    required this.color,
    required this.widths,
    required this.points,
  });
}

class XoppImageElement extends XoppElement {
  final double left;
  final double top;
  final double right;
  final double bottom;
  final Uint8List imageBytes;
  ui.Image? decodedImage;

  XoppImageElement({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.imageBytes,
  });
}
