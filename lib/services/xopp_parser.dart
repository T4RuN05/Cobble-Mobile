import 'dart:io';
import 'dart:ui';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import '../models/xopp_document.dart';

class XoppParser {
  /// Parses a .xopp file completely in a background Isolate to prevent UI lag.
  static Future<XoppDocument> parseFile(String filePath) async {
    return await compute(_parseInIsolate, filePath);
  }

  /// The heavy lifting function that runs in the Isolate.
  static XoppDocument _parseInIsolate(String filePath) {
    final fileBytes = File(filePath).readAsBytesSync();
    
    // Decompress the GZip payload
    final decompressed = GZipDecoder().decodeBytes(fileBytes);
    final xmlString = String.fromCharCodes(decompressed);
    
    // Parse the XML
    final document = XmlDocument.parse(xmlString);
    final root = document.findElements('xournal').first;

    final pages = <XoppPage>[];
    
    for (final pageElement in root.findElements('page')) {
      final width = double.parse(pageElement.getAttribute('width') ?? '0');
      final height = double.parse(pageElement.getAttribute('height') ?? '0');
      
      // Parse Background
      final bgElement = pageElement.findElements('background').first;
      final bgType = bgElement.getAttribute('type') ?? '';
      
      XoppBackground background;
      if (bgType == 'pdf') {
        background = PdfBackground(
          filename: bgElement.getAttribute('filename') ?? '',
          pageNo: int.parse(bgElement.getAttribute('pageno') ?? '1'),
        );
      } else {
        background = SolidBackground(
          color: _parseColor(bgElement.getAttribute('color') ?? '#ffffff'),
          style: bgElement.getAttribute('style') ?? 'solid',
        );
      }

      // Parse Layers and Strokes/Images
      final layers = <XoppLayer>[];
      for (final layerElement in pageElement.findElements('layer')) {
        final elements = <XoppElement>[];
        
        for (final node in layerElement.children) {
          if (node is XmlElement) {
            if (node.name.local == 'stroke') {
              final tool = node.getAttribute('tool') ?? 'pen';
              final color = _parseColor(node.getAttribute('color') ?? '#000000');
              
              final widthString = node.getAttribute('width') ?? '';
              final widths = widthString.split(' ').map((e) => double.tryParse(e) ?? 1.0).toList();
              
              final pointsString = node.innerText.trim();
              final coords = pointsString.split(' ');
              final points = <Offset>[];
              
              for (var i = 0; i < coords.length - 1; i += 2) {
                final x = double.tryParse(coords[i]) ?? 0;
                final y = double.tryParse(coords[i + 1]) ?? 0;
                points.add(Offset(x, y));
              }
              
              elements.add(XoppStroke(
                tool: tool,
                color: color,
                widths: widths,
                points: points,
              ));
            } else if (node.name.local == 'image') {
              final left = double.tryParse(node.getAttribute('left') ?? '0') ?? 0;
              final top = double.tryParse(node.getAttribute('top') ?? '0') ?? 0;
              final right = double.tryParse(node.getAttribute('right') ?? '0') ?? 0;
              final bottom = double.tryParse(node.getAttribute('bottom') ?? '0') ?? 0;
              
              final base64String = node.innerText.trim();
              try {
                final bytes = base64Decode(base64String);
                elements.add(XoppImageElement(
                  left: left,
                  top: top,
                  right: right,
                  bottom: bottom,
                  imageBytes: bytes,
                ));
              } catch (e) {
                debugPrint("Failed to decode base64 image: $e");
              }
            }
          }
        }
        layers.add(XoppLayer(elements: elements));
      }
      
      pages.add(XoppPage(
        width: width,
        height: height,
        background: background,
        layers: layers,
      ));
    }
    
    return XoppDocument(pages: pages);
  }

  static Color _parseColor(String hexString) {
    if (hexString.startsWith('#')) {
      if (hexString.length == 7) {
        // #RRGGBB
        return Color(int.parse(hexString.substring(1), radix: 16) + 0xFF000000);
      } else if (hexString.length == 9) {
        // #RRGGBBAA -> AARRGGBB
        final r = hexString.substring(1, 3);
        final g = hexString.substring(3, 5);
        final b = hexString.substring(5, 7);
        final a = hexString.substring(7, 9);
        return Color(int.parse('$a$r$g$b', radix: 16));
      }
    }
    return const Color(0xFFFFFFFF); // Default to white for backgrounds if missing
  }
}
