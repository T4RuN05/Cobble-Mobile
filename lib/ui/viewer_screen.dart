import 'dart:io';
import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';
import '../models/xopp_document.dart';
import 'xopp_painter.dart';
import '../services/supabase_service.dart';
import '../services/xopp_renderer.dart';
import '../services/pdf_export_service.dart';
import 'package:share_plus/share_plus.dart';

class ViewerScreen extends StatefulWidget {
  final XoppDocument document;
  final String? originalFileName;
  final DateTime documentLastModified;

  const ViewerScreen({
    Key? key, 
    required this.document, 
    required this.documentLastModified,
    this.originalFileName,
  }) : super(key: key);

  @override
  _ViewerScreenState createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  final Map<int, ui.Image> _pdfImages = {};
  bool _isLoadingPdf = false;
  bool _isRenderingGraphics = true;
  
  final ValueNotifier<int> _visiblePage = ValueNotifier<int>(1);
  final ValueNotifier<double> _scrollProgress = ValueNotifier<double>(0.0);
  final ValueNotifier<bool> _isPillVisible = ValueNotifier<bool>(false);
  
  Timer? _pillTimer;
  final TransformationController _transformationController = TransformationController();
  late final List<GlobalKey> _pageKeys;
  bool _isDraggingPill = false;
  bool _isExporting = false;
  
  bool _isOverlayForced = false;
  final ValueNotifier<double> _headerTop = ValueNotifier(0.0);
  double _lastTy = 0.0;

  @override
  void initState() {
    super.initState();
    _pageKeys = List.generate(widget.document.pages.length, (_) => GlobalKey());
    _transformationController.addListener(_onTransformChanged);
    _initializeViewer();
  }

  @override
  void dispose() {
    _pillTimer?.cancel();
    _transformationController.removeListener(_onTransformChanged);
    _transformationController.dispose();
    super.dispose();
  }

  void _showPillIndicator() {
    _pillTimer?.cancel();
    
    if (!_isPillVisible.value) {
      _isPillVisible.value = true;
    }
    
    _pillTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) {
        _isPillVisible.value = false;
      }
    });
  }

  void _onTransformChanged() {
    if (_isDraggingPill) return;
    if (widget.document.pages.isEmpty) return;

    if (!mounted) return;
    final screenHeight = MediaQuery.of(context).size.height;
    final screenCenterY = screenHeight / 2;
    
    int? visiblePageIndex;

    // 1. Find which page intersects the center of the screen
    for (int i = 0; i < _pageKeys.length; i++) {
      final key = _pageKeys[i];
      if (key.currentContext == null) continue;
      
      final RenderBox? box = key.currentContext!.findRenderObject() as RenderBox?;
      if (box == null) continue;
      
      final position = box.localToGlobal(Offset.zero);
      // Check if the center of the screen falls within this page's physical bounds
      if (screenCenterY >= position.dy && screenCenterY <= position.dy + box.size.height) {
        visiblePageIndex = i;
        break;
      }
    }
    
    // Fallback: if we scrolled past the bottom, show the last page.
    if (visiblePageIndex == null && _pageKeys.isNotEmpty) {
      final lastKey = _pageKeys.last;
      if (lastKey.currentContext != null) {
        final box = lastKey.currentContext!.findRenderObject() as RenderBox?;
        if (box != null) {
          final position = box.localToGlobal(Offset.zero);
          if (screenCenterY > position.dy + box.size.height) {
            visiblePageIndex = _pageKeys.length - 1;
          }
        }
      }
    }

    if (visiblePageIndex != null && _visiblePage.value != visiblePageIndex + 1) {
      _visiblePage.value = visiblePageIndex + 1;
    }

    // 2. Calculate exact scroll progress using the true render bounds
    if (_pageKeys.isNotEmpty) {
      final firstKey = _pageKeys.first;
      final lastKey = _pageKeys.last;
      
      if (firstKey.currentContext != null && lastKey.currentContext != null) {
        final firstBox = firstKey.currentContext!.findRenderObject() as RenderBox;
        final lastBox = lastKey.currentContext!.findRenderObject() as RenderBox;
        
        final topOfDocument = firstBox.localToGlobal(Offset.zero).dy;
        final bottomOfDocument = lastBox.localToGlobal(Offset.zero).dy + lastBox.size.height;
        
        final documentHeightOnScreen = bottomOfDocument - topOfDocument;
        
        if (documentHeightOnScreen > screenHeight) {
          // Adjust scroll distance to account for the header padding if needed
          double scrollDistance = -topOfDocument; 
          double maxScroll = documentHeightOnScreen - screenHeight;
          
          double progress = maxScroll > 0 ? (scrollDistance / maxScroll) : 0.0;
          if (progress < 0.0) progress = 0.0;
          if (progress > 1.0) progress = 1.0;
          
          _scrollProgress.value = progress;
        } else {
          _scrollProgress.value = 0.0;
        }
      }
    }

    final double headerHeight = kToolbarHeight + MediaQuery.of(context).padding.top;
    final ty = _transformationController.value.getTranslation().y;
    
    if (_lastTy != ty) {
      if (_isOverlayForced) {
        // Clear forced overlay if user actively pans
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _isOverlayForced = false);
        });
      }
      _lastTy = ty;
    }

    double targetTop = ty;
    if (targetTop < -headerHeight) targetTop = -headerHeight;
    if (targetTop > 0) targetTop = 0.0;
    
    if (!_isOverlayForced) {
      _headerTop.value = targetTop;
    }

    _showPillIndicator();
  }

  Future<void> _initializeViewer() async {
    // Load any PDF backgrounds first
    await _loadPdfBackgrounds();
    
    // Asynchronously pre-rasterize or load from disk cache
    await XoppRenderer.rasterizeDocument(
      widget.document,
      widget.originalFileName ?? 'unknown',
      widget.documentLastModified,
    );
    
    if (mounted) {
      setState(() => _isRenderingGraphics = false);
    }
  }

  Future<void> _loadPdfBackgrounds() async {
    final pdfPages = widget.document.pages.where((p) => p.background is PdfBackground);
    if (pdfPages.isEmpty) return;

    setState(() => _isLoadingPdf = true);

    try {
      final bg = pdfPages.first.background as PdfBackground;
      final pdfFilename = bg.filename.split('/').last;

      final pdfFile = await SupabaseService.downloadXoppFile(pdfFilename);
      final pdfDoc = await PdfDocument.openFile(pdfFile.path);

      for (var i = 0; i < widget.document.pages.length; i++) {
        final pageBg = widget.document.pages[i].background;
        if (pageBg is PdfBackground) {
          final pdfPage = await pdfDoc.getPage(pageBg.pageNo);
          final pageImage = await pdfPage.render(
            width: pdfPage.width * 2,
            height: pdfPage.height * 2,
            format: PdfPageImageFormat.png,
          );

          if (pageImage != null) {
            final codec = await ui.instantiateImageCodec(pageImage.bytes);
            final frame = await codec.getNextFrame();
            _pdfImages[i] = frame.image;
          }
          await pdfPage.close();
        }
      }
      
      await pdfDoc.close();
    } catch (e) {
      debugPrint("Error loading PDF: $e");
    } finally {
      if (mounted) setState(() => _isLoadingPdf = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.document.pages.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Empty Document')),
        body: const Center(child: Text('No pages found.')),
      );
    }


    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      body: _isLoadingPdf || _isRenderingGraphics
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  Text(
                    _isRenderingGraphics ? 'Baking High-Res Graphics...' : 'Loading PDF...',
                    style: const TextStyle(color: Colors.white70),
                  )
                ],
              ),
            )
          : Stack(
              children: [
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _isOverlayForced = !_isOverlayForced;
                    });
                  },
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final firstPage = widget.document.pages.first;
                      final scale = constraints.maxWidth / firstPage.width;
                      final initialScale = scale > 1.5 ? 1.5 : scale;
                      final headerHeight = kToolbarHeight + MediaQuery.of(context).padding.top;
                      
                      if (_transformationController.value == Matrix4.identity()) {
                        _transformationController.value = Matrix4.identity()..scale(initialScale);
                      }

                      return InteractiveViewer(
                        transformationController: _transformationController,
                        minScale: 0.1,
                        maxScale: 5.0,
                        boundaryMargin: EdgeInsets.zero,
                        constrained: false,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(height: headerHeight / initialScale),
                              ...List.generate(widget.document.pages.length, (index) {
                                final page = widget.document.pages[index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 24.0),
                                child: RepaintBoundary(
                                  key: _pageKeys[index],
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      border: Border.all(color: Colors.black26, width: 1),
                                    ),
                                    child: CustomPaint(
                                      size: Size(page.width, page.height),
                                      painter: XoppPainter(
                                        page: page,
                                        pdfImage: _pdfImages[index],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }),
                            ],
                          ),
                        ),
                      );
                    }
                  ),
                ),
                // GDrive-style Scroll Pill
                ValueListenableBuilder<double>(
                  valueListenable: _scrollProgress,
                  builder: (context, progress, child) {
                    // Calculate vertical position based on scroll progress
                    // Leave some padding so it doesn't clip the top/bottom edges
                    final screenHeight = MediaQuery.of(context).size.height;
                    final topOffset = 20.0 + (screenHeight - 80.0) * progress;
                    
                    return Positioned(
                      top: topOffset,
                      right: 12,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _isPillVisible,
                        builder: (context, isVisible, child) {
                          return AnimatedOpacity(
                            opacity: isVisible ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 300),
                            child: GestureDetector(
                              onVerticalDragStart: (_) {
                                _isDraggingPill = true;
                                _showPillIndicator();
                              },
                              onVerticalDragEnd: (_) {
                                _isDraggingPill = false;
                                _onTransformChanged();
                              },
                              onVerticalDragCancel: () {
                                _isDraggingPill = false;
                                _onTransformChanged();
                              },
                              onVerticalDragUpdate: (details) {
                                if (_pageKeys.isEmpty) return;
                                final firstKey = _pageKeys.first;
                                final lastKey = _pageKeys.last;
                                if (firstKey.currentContext == null || lastKey.currentContext == null) return;
                                
                                final screenHeight = MediaQuery.of(context).size.height;
                                final trackHeight = screenHeight - 80.0;
                                
                                final progressDelta = details.delta.dy / trackHeight;
                                
                                double newProgress = _scrollProgress.value + progressDelta;
                                if (newProgress < 0.0) newProgress = 0.0;
                                if (newProgress > 1.0) newProgress = 1.0;
                                
                                _scrollProgress.value = newProgress;
                                
                                final firstBox = firstKey.currentContext!.findRenderObject() as RenderBox;
                                final lastBox = lastKey.currentContext!.findRenderObject() as RenderBox;
                                
                                final topOfDocument = firstBox.localToGlobal(Offset.zero).dy;
                                final bottomOfDocument = lastBox.localToGlobal(Offset.zero).dy + lastBox.size.height;
                                final documentHeightOnScreen = bottomOfDocument - topOfDocument;
                                
                                final maxScroll = documentHeightOnScreen - screenHeight;
                                if (maxScroll <= 0) return;
                                
                                final targetTop = -(newProgress * maxScroll);
                                final diff = targetTop - topOfDocument;
                                
                                final matrix = _transformationController.value;
                                final newMatrix = matrix.clone();
                                newMatrix.setTranslationRaw(
                                  matrix.getTranslation().x, 
                                  matrix.getTranslation().y + diff, 
                                  matrix.getTranslation().z
                                );
                                
                                _transformationController.value = newMatrix;
                                _showPillIndicator();
                                
                                final screenCenterY = screenHeight / 2;
                                int? visiblePageIndex;
                                for (int i = 0; i < _pageKeys.length; i++) {
                                  final key = _pageKeys[i];
                                  if (key.currentContext == null) continue;
                                  final box = key.currentContext!.findRenderObject() as RenderBox?;
                                  if (box == null) continue;
                                  
                                  final position = box.localToGlobal(Offset.zero);
                                  final predictedY = position.dy + diff;
                                  
                                  if (screenCenterY >= predictedY && screenCenterY <= predictedY + box.size.height) {
                                    visiblePageIndex = i;
                                    break;
                                  }
                                }
                                
                                if (visiblePageIndex != null && _visiblePage.value != visiblePageIndex + 1) {
                                  _visiblePage.value = visiblePageIndex + 1;
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2D2D2D).withOpacity(0.9),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.white24, width: 1),
                                  boxShadow: const [
                                    BoxShadow(color: Colors.black45, blurRadius: 4, offset: Offset(0, 2))
                                  ],
                                ),
                                child: ValueListenableBuilder<int>(
                                  valueListenable: _visiblePage,
                                  builder: (context, page, child) {
                                    return Text(
                                      '$page / ${widget.document.pages.length}',
                                      style: const TextStyle(
                                        color: Colors.white, 
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    );
                                  }
                                ),
                              ),
                            ),
                          );
                        }
                      ),
                    );
                  }
                ),
                // GDrive Style Overlay Header
                ValueListenableBuilder<double>(
                  valueListenable: _headerTop,
                  builder: (context, headerTop, child) {
                    final headerHeight = kToolbarHeight + MediaQuery.of(context).padding.top;
                    return AnimatedPositioned(
                      duration: _isOverlayForced ? const Duration(milliseconds: 250) : Duration.zero,
                      curve: Curves.easeInOutCubic,
                      top: _isOverlayForced ? 0.0 : headerTop,
                      left: 0,
                      right: 0,
                      height: headerHeight,
                      child: Container(
                        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2D2D2D).withOpacity(0.95),
                          boxShadow: const [
                            BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: Row(
                            children: [
                              const BackButton(color: Colors.white),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  (widget.originalFileName ?? 'Document Viewer').split('/').last,
                                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert, color: Colors.white),
                                color: const Color(0xFF2D2D2D),
                                onSelected: (value) {
                                  if (value == 'export') {
                                    _showExportModal(context);
                                  } else if (value == 'about') {
                                    _showAboutDialog(context);
                                  }
                                },
                                itemBuilder: (context) => [
                                  const PopupMenuItem(
                                    value: 'export',
                                    child: Row(
                                      children: [
                                        Icon(Icons.picture_as_pdf, color: Colors.white70, size: 20),
                                        SizedBox(width: 12),
                                        Text('Export as PDF', style: TextStyle(color: Colors.white)),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'about',
                                    child: Row(
                                      children: [
                                        Icon(Icons.info_outline, color: Colors.white70, size: 20),
                                        SizedBox(width: 12),
                                        Text('About File', style: TextStyle(color: Colors.white)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                ),
              ],
            ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF2D2D2D),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('File Details', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(width: 120, child: Text('Filename', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold))),
                  Expanded(child: Text((widget.originalFileName ?? 'Unknown').split('/').last, style: const TextStyle(color: Colors.white))),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(width: 120, child: Text('Pages', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold))),
                  Expanded(child: Text('${widget.document.pages.length}', style: const TextStyle(color: Colors.white))),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(width: 120, child: Text('Last Modified', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold))),
                  Expanded(child: Text(widget.documentLastModified.toLocal().toString().split('.')[0], style: const TextStyle(color: Colors.white))),
                ],
              ),
              const SizedBox(height: 30),
            ],
          ),
        );
      }
    );
  }

  void _showExportModal(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        bool isGenerating = false;
        
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF2D2D2D),
              title: const Text('Export to PDF', style: TextStyle(color: Colors.white)),
              content: isGenerating
                  ? const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.blueAccent),
                        SizedBox(height: 20),
                        Text('Generating high-quality PDF...', style: TextStyle(color: Colors.white70)),
                      ],
                    )
                  : const Text('Do you want to export this document as a PDF?', style: TextStyle(color: Colors.white70)),
              actions: isGenerating
                  ? []
                  : [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                        onPressed: () async {
                          setDialogState(() => isGenerating = true);
                          // Yield the event loop to ensure the loading spinner renders before CPU blocks
                          await Future.delayed(const Duration(milliseconds: 100));
                          try {
                            final file = await PdfExportService.generatePdf(
                              widget.document, 
                              _pdfImages, 
                              widget.originalFileName ?? 'document.xopp',
                            );
                            
                            if (mounted) {
                              Navigator.pop(dialogContext);
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                const SnackBar(content: Text('Export Successful!'), backgroundColor: Colors.green),
                              );
                              final xFile = XFile(file.path, mimeType: 'application/pdf');
                              await Share.shareXFiles([xFile], text: 'Exported from Cobble Mobile');
                            }
                          } catch (e) {
                            if (mounted) {
                              Navigator.pop(dialogContext);
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(content: Text('Failed to export: $e'), backgroundColor: Colors.red),
                              );
                            }
                          }
                        },
                        child: const Text('Export', style: TextStyle(color: Colors.white)),
                      ),
                    ],
            );
          },
        );
      },
    );
  }
}

