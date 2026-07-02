import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import '../models/xopp_document.dart';
import 'storage_service.dart';

class PdfExportService {
  /// Exports the given XoppDocument to a standard PDF and shares it.
  /// To bypass the limitation of the `pdf` package not reading existing PDFs,
  /// this rasterizes the PDF background pages (if any) and embeds them as images,
  /// while perfectly preserving the vector math of the strokes.
  static Future<File> generatePdf(
    XoppDocument document, 
    Map<int, ui.Image> pdfBackgroundImages,
    String originalFilename,
  ) async {
    final pdf = pw.Document(
      title: originalFilename,
      creator: 'Cobble Mobile',
    );

    for (int i = 0; i < document.pages.length; i++) {
      // Yield to event loop to keep the UI spinner animating
      await Future.delayed(Duration.zero);
      
      final page = document.pages[i];
      final bgImage = pdfBackgroundImages[i];
      
      Uint8List? bgBytes;
      if (bgImage != null) {
        final byteData = await bgImage.toByteData(format: ui.ImageByteFormat.png);
        if (byteData != null) {
          bgBytes = byteData.buffer.asUint8List();
        }
      }

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(page.width, page.height),
          margin: pw.EdgeInsets.zero,
          build: (pw.Context context) {
            return pw.Container(
              width: page.width,
              height: page.height,
              child: pw.Stack(
                children: [
                  // 1. Draw Background
                  if (bgBytes != null)
                    pw.Positioned.fill(
                      child: pw.Image(pw.MemoryImage(bgBytes), fit: pw.BoxFit.fill),
                    )
                  else
                    pw.Positioned.fill(
                      child: _buildSolidBackground(page.background),
                    ),

                  // 2. Draw Vector Strokes
                  pw.Positioned.fill(
                    child: pw.CustomPaint(
                      size: PdfPoint(page.width, page.height),
                      painter: (PdfGraphics canvas, PdfPoint size) {
                        _drawStrokes(canvas, size, page);
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    }

    final bytes = await pdf.save();
    
    final dirPath = await StorageService.getStorageDirectory();
    final exportName = originalFilename.replaceAll('.xopp', '.pdf');
    final file = File('$dirPath/$exportName');
    await file.writeAsBytes(bytes, flush: true);
    
    return file;
  }

  static pw.Widget _buildSolidBackground(XoppBackground background) {
    if (background is SolidBackground) {
      // PDF background color
      final color = PdfColor(
        background.color.red / 255.0,
        background.color.green / 255.0,
        background.color.blue / 255.0,
      );
      return pw.Container(
        color: color,
      );
    }
    return pw.Container(color: PdfColors.white);
  }

  static void _drawStrokes(PdfGraphics canvas, PdfPoint size, XoppPage page) {
    for (final layer in page.layers) {
      for (final element in layer.elements) {
        if (element is XoppStroke) {
          if (element.points.isEmpty) continue;
          
          final color = PdfColor.fromInt(element.color.value);
          
          if (element.tool == 'highlighter') {
            canvas.saveContext();
            // Note: the dart `pdf` package doesn't have a direct blend mode API natively exposed 
            // easily on the canvas in all versions, so we fall back to generic alpha transparency
            canvas.setGraphicState(PdfGraphicState(opacity: 0.5));
          }

          if (element.widths.length <= 1) {
            // Constant pressure
            canvas.setColor(color);
            canvas.setLineWidth(element.widths.isNotEmpty ? element.widths.first : 1.0);
            canvas.setLineCap(PdfLineCap.round);
            canvas.setLineJoin(PdfLineJoin.round);
            
            final firstPt = element.points.first;
            // Map Y coordinates: Xournal++ (top=0) -> PDF (bottom=0)
            canvas.moveTo(firstPt.dx, size.y - firstPt.dy);
            
            for (var i = 1; i < element.points.length; i++) {
              final pt = element.points[i];
              canvas.lineTo(pt.dx, size.y - pt.dy);
            }
            canvas.strokePath();
          } else {
            // Variable pressure
            canvas.setColor(color);
            canvas.setLineCap(PdfLineCap.round);
            canvas.setLineJoin(PdfLineJoin.round);

            for (var i = 1; i < element.points.length; i++) {
              final w = element.widths.length > i ? element.widths[i] : element.widths.last;
              canvas.setLineWidth(w);
              
              final ptPrev = element.points[i - 1];
              final ptCurr = element.points[i];
              
              canvas.moveTo(ptPrev.dx, size.y - ptPrev.dy);
              canvas.lineTo(ptCurr.dx, size.y - ptCurr.dy);
              canvas.strokePath();
            }
          }
          
          if (element.tool == 'highlighter') {
            canvas.restoreContext();
          }
        }
      }
    }
  }
}
