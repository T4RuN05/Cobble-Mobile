# Native C++ Stroke Engine on Flutter Mobile
## Comprehensive Architecture for Porting the Xournal++ Rendering Core

---

## 1. The Problem Statement

Flutter's built-in `CustomPainter` + `Canvas` API is fundamentally designed for UI rendering, not for replicating a professional handwriting engine. After extensive testing in the `COBBLE` prototype, we confirmed that:

- **Dart-side stroke smoothing** produces rigid, angular strokes because Flutter's `Canvas.drawPath()` does not natively handle per-point variable-width pressure rendering.
- **Pressure interpolation** in Dart is too slow at high sample rates (240Hz+ stylus input on modern tablets), causing visible lag and dropped samples.
- **Contour generation** (the mathematical process of turning a polyline with pressure data into a filled polygon with smooth, organic edges) is computationally expensive and benefits enormously from C++ optimizations (SIMD, cache locality, zero-copy memory).

Meanwhile, Xournal++'s C++ engine has spent **years** perfecting its stroke pipeline. It includes:

| Component | File | Purpose |
|---|---|---|
| `Point` | `model/Point.h` | 3-axis point (x, y, pressure) with distance/interpolation math |
| `Stroke` | `model/Stroke.h/cpp` | 876-line stroke model with pressure arrays, bounding boxes, intersection tests |
| `StrokeContour` | `model/StrokeContour.cpp` | 355-line contour generator: converts pressure-polyline into filled polygon with arc couplings |
| `SplineSegment` | `model/SplineSegment.cpp` | Bézier subdivision for smooth curves with adaptive flatness tolerance |
| `StrokeStabilizer` | `control/tools/StrokeStabilizer.h` | 587-line stabilizer framework: Deadzone, Inertia, Gaussian, and hybrid algorithms |
| `StrokeHandler` | `control/tools/StrokeHandler.cpp` | Input pipeline: pressure scaling, width variation decomposition, minimum motion thresholds |
| `StrokeViewHelper` | `view/StrokeViewHelper.cpp` | Cairo rendering: `drawWithPressure()` using contour fill, `drawNoPressure()` using line stroke |
| `MathVect` | `model/MathVect.h` | 2D vector math for contour angle/normal calculations |

**Our goal:** Run this exact C++ engine on mobile, under the Flutter UI shell.

---

## 2. Comparative Analysis: Why the Official `xournalpp_mobile` App Lags

The official `xournalpp_mobile` repository (also built in Flutter) attempts to solve this problem using pure Dart. However, it suffers from severe performance degradation and high latency on Android devices. An architectural analysis of their codebase reveals several critical bottlenecks that our native C++ approach specifically solves:

### 2.1 The "Widget-Per-Stroke" Anti-Pattern
In `xournalpp_mobile`, the canvas is constructed using an `XppPageStack` which loops through every stroke and creates a separate `Positioned` widget containing a `CustomPaint` widget for it (see `XppLayerStack.dart` and `XppStroke.dart`). 
- **The Problem:** If a user writes a page of notes (e.g., 1,000 individual strokes), Flutter has to maintain 1,000 `CustomPaint` widgets in its render tree. This completely overwhelms Flutter's layout and composite phases, leading to dramatic frame drops when zooming, panning, or rendering.
- **Our Solution:** The C++ engine renders *all* strokes onto a single in-memory Cairo pixel buffer. Flutter only ever renders **one** widget (a `Texture` or `RawImage`), maintaining a flat, O(1) widget tree regardless of how much ink is on the page.

### 2.2 Naive Pressure Rendering
In `XppStrokePainter.dart`, the official app tries to render pressure by looping over every single point in the stroke. It creates a brand new `Path` and `Paint` object for the tiny segment between point `i-1` and `i`, explicitly setting the `strokeWidth` for just that segment.
- **The Problem:** Allocating thousands of `Paint` objects and dispatching thousands of individual `Canvas.drawPath` calls per frame is exceptionally slow. Furthermore, it produces visually ugly, jagged "sausage link" strokes because it draws discrete line segments rather than calculating a smooth contour.
- **Our Solution:** The C++ `StrokeContour` algorithm computes a mathematically smooth polygon boundary that encapsulates the varying pressure across the entire stroke, then issues a single highly-optimized `cairo_fill()` command.

### 2.3 Main-Thread CPU Bottlenecks
The official app parses `.xopp` XML files (which can be megabytes in size) and calculates eraser intersections (`XppStroke.eraseWhere`) using pure Dart on the main UI thread. 
- **The Problem:** When erasing, `filterEraser()` iterates through every point of every stroke in the document on the main thread to perform radial intersection tests. This causes severe stuttering and unresponsive UI.
- **Our Solution:** The C++ engine handles all intersection math natively in a highly optimized way (using spatial caching and SIMD), keeping the heavy computational load off Flutter's UI isolate.

---

## 3. Architecture Decision: Why `dart:ffi` + Shared Memory Buffer

After evaluating all viable approaches, here is the verdict:

### Approaches Evaluated

| Approach | Latency | Complexity | Verdict |
|---|---|---|---|
| **Pure Dart rewrite** | High (GC pauses, no SIMD) | Medium | ❌ Already failed in COBBLE prototype |
| **Platform Channels** | High (JSON serialization per event) | Low | ❌ Unusable at 240Hz stylus input |
| **PlatformView (native SurfaceView)** | Low | Very High | ⚠️ Works but fights Flutter's compositor |
| **`dart:ffi` + Pixel Buffer** | **Lowest** | Medium-High | ✅ **Selected approach** |
| **Flutter GPU (experimental)** | Low | Very High | ⚠️ Too unstable for production (2026) |

### Why `dart:ffi` + Pixel Buffer Wins

1. **Zero-copy memory sharing.** Dart FFI can directly read a `Pointer<Uint8>` pointing to a C++ pixel buffer. No serialization, no copying.
2. **C++ runs at native speed.** The stroke stabilizer, contour generator, and Cairo renderer all execute in C++ without any Dart overhead.
3. **Flutter handles everything else.** The toolbar, file browser, sync engine, and all non-drawing UI remains in Flutter (where it excels).
4. **Cross-platform.** The same `.so` (Android) and `.dylib` (iOS) compile from identical C++ source.

---

## 4. High-Level System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    FLUTTER UI SHELL                      │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐             │
│  │ Toolbar  │  │ File     │  │ Sync      │             │
│  │ (Dart)   │  │ Browser  │  │ Engine    │             │
│  │          │  │ (Dart)   │  │ (Dart)    │             │
│  └──────────┘  └──────────┘  └───────────┘             │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │              CANVAS VIEWPORT                     │   │
│  │    ┌───────────────────────────────────────┐    │   │
│  │    │   RawImage / Texture Widget           │    │   │
│  │    │   (Displays C++ pixel buffer)         │    │   │
│  │    └────────────────┬──────────────────────┘    │   │
│  │                     │ Pointer<Uint8>             │   │
│  └─────────────────────┼───────────────────────────┘   │
│                        │                                │
│  ┌─────────────────────┼───────────────────────────┐   │
│  │     Dart FFI Bridge │                            │   │
│  │  ┌─────────────────┐│┌──────────────────────┐   │   │
│  │  │ GestureDetector ││| cobble_ffi_bindings  │   │   │
│  │  │ (captures touch ││| (auto-generated)     │   │   │
│  │  │  x, y, pressure)││└──────────────────────┘   │   │
│  │  └─────────────────┘│                            │   │
│  └─────────────────────┼───────────────────────────┘   │
│                        │                                │
├════════════════════════╪════════════════════════════════┤
│          NATIVE C++ ENGINE (libcobble_engine)           │
│                        │                                │
│  ┌─────────────────────▼───────────────────────────┐   │
│  │              CobbleEngine (C API)                │   │
│  │  ┌──────────────────────────────────────────┐   │   │
│  │  │ engine_on_stylus_down(x, y, pressure)    │   │   │
│  │  │ engine_on_stylus_move(x, y, pressure)    │   │   │
│  │  │ engine_on_stylus_up(x, y, pressure)      │   │   │
│  │  │ engine_render(buffer*, width, height)     │   │   │
│  │  │ engine_set_tool(pen/eraser/highlighter)   │   │   │
│  │  │ engine_set_color(r, g, b, a)              │   │   │
│  │  │ engine_set_width(double)                  │   │   │
│  │  │ engine_undo() / engine_redo()             │   │   │
│  │  │ engine_load_xopp(path) / engine_save()    │   │   │
│  │  └──────────────────────────────────────────┘   │   │
│  │                                                  │   │
│  │  ┌────────────┐ ┌──────────────┐ ┌───────────┐ │   │
│  │  │   Stroke    │ │StrokeContour │ │  Stroke   │ │   │
│  │  │   Model     │ │  Generator   │ │ Stabilizer│ │   │
│  │  │ (Point.h,   │ │(StrokeContour│ │(Deadzone, │ │   │
│  │  │  Stroke.h)  │ │  .cpp)       │ │ Inertia,  │ │   │
│  │  │             │ │              │ │ Gaussian) │ │   │
│  │  └──────┬──────┘ └──────┬───────┘ └─────┬─────┘ │   │
│  │         │               │               │        │   │
│  │  ┌──────▼───────────────▼───────────────▼──────┐ │   │
│  │  │         Cairo 2D Rendering Engine            │ │   │
│  │  │  (renders to in-memory image surface)        │ │   │
│  │  └──────────────────────────────────────────────┘ │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

---

## 5. What Exactly Gets Ported from Xournal++

### 5.1 Files to Extract (Zero GTK Dependencies)

The following files from `src/core/` can be extracted almost verbatim because they are pure math/data with no GTK or UI dependencies:

```
model/Point.h               model/Point.cpp
model/Stroke.h              model/Stroke.cpp
model/StrokeContour.h       model/StrokeContour.cpp
model/SplineSegment.h       model/SplineSegment.cpp
model/MathVect.h            model/MathVect.cpp
model/LineStyle.h           model/LineStyle.cpp
model/Element.h             model/Element.cpp
model/PathParameter.h
```

### 5.2 Files Requiring Modification

These files have GTK/GLib/Settings dependencies that must be stripped:

| File | What to Strip | What to Keep |
|---|---|---|
| `StrokeHandler.cpp` | GTK event types, `Control*`, `UndoRedoHandler`, `ShapeRecognizer` | `paintTo()`, `drawSegmentTo()`, pressure decomposition logic |
| `StrokeStabilizer.h/cpp` | `Settings*` dependency, `guint32` timestamps | All stabilizer algorithms (Deadzone, Inertia, VelocityGaussian, Arithmetic, hybrids) |
| `StrokeViewHelper.cpp` | Nothing (pure Cairo) | `drawWithPressure()`, `drawNoPressure()`, `pathToCairo()` |
| `StrokeView.cpp` | Mask system, highlighter blending | Core `draw()` flow for pressure/no-pressure paths |
| `ErasableStrokeView.cpp` | Nothing significant | Eraser rendering logic |

### 5.3 External Dependency: Cairo

Cairo is the critical rendering backend. It is:
- ✅ Already cross-platform (Linux, Windows, macOS, Android, iOS)
- ✅ Available as a static library for Android NDK and iOS
- ✅ Renders to in-memory `CAIRO_FORMAT_ARGB32` image surfaces (perfect for pixel buffer sharing)

Cairo will be compiled as a static library and linked into `libcobble_engine`.

---

## 6. The C API Bridge (`cobble_engine_api.h`)

All communication between Flutter and C++ goes through a flat C API (no C++ name mangling):

```c
// cobble_engine_api.h
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stdbool.h>

// Lifecycle
void* cobble_engine_create(int canvas_width, int canvas_height);
void  cobble_engine_destroy(void* engine);
void  cobble_engine_resize(void* engine, int width, int height);

// Pixel buffer access (zero-copy)
uint8_t* cobble_engine_get_pixel_buffer(void* engine);
int      cobble_engine_get_buffer_size(void* engine);

// Stylus input pipeline
void cobble_engine_stylus_down(void* engine, double x, double y, double pressure);
void cobble_engine_stylus_move(void* engine, double x, double y, double pressure);
void cobble_engine_stylus_up(void* engine, double x, double y, double pressure);

// Tool configuration
void cobble_engine_set_tool(void* engine, int tool);  // 0=PEN, 1=ERASER, 2=HIGHLIGHTER
void cobble_engine_set_color(void* engine, uint8_t r, uint8_t g, uint8_t b, uint8_t a);
void cobble_engine_set_stroke_width(void* engine, double width);
void cobble_engine_set_stabilizer(void* engine, int type, double param1, double param2);

// Viewport
void cobble_engine_set_zoom(void* engine, double zoom);
void cobble_engine_set_scroll(void* engine, double offset_x, double offset_y);

// Rendering
bool cobble_engine_render(void* engine);  // Returns true if buffer was modified

// Document I/O
bool cobble_engine_load_xopp(void* engine, const char* filepath);
bool cobble_engine_save_xopp(void* engine, const char* filepath);

// Undo/Redo
void cobble_engine_undo(void* engine);
void cobble_engine_redo(void* engine);

// Page management
int  cobble_engine_get_page_count(void* engine);
void cobble_engine_set_current_page(void* engine, int page_index);
void cobble_engine_add_page(void* engine);

#ifdef __cplusplus
}
#endif
```

---

## 7. The Dart FFI Binding Layer

### 7.1 Loading the Native Library

```dart
// lib/native/cobble_engine_bindings.dart
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:ffi/ffi.dart';

class CobbleEngineBindings {
  static final DynamicLibrary _lib = Platform.isAndroid
      ? DynamicLibrary.open('libcobble_engine.so')
      : DynamicLibrary.process(); // iOS embeds statically

  // Lifecycle
  static final _create = _lib.lookupFunction<
      Pointer<Void> Function(Int32, Int32),
      Pointer<Void> Function(int, int)>('cobble_engine_create');

  static final _destroy = _lib.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('cobble_engine_destroy');

  // Stylus input
  static final _stylusDown = _lib.lookupFunction<
      Void Function(Pointer<Void>, Double, Double, Double),
      void Function(Pointer<Void>, double, double, double)>('cobble_engine_stylus_down');

  static final _stylusMove = _lib.lookupFunction<
      Void Function(Pointer<Void>, Double, Double, Double),
      void Function(Pointer<Void>, double, double, double)>('cobble_engine_stylus_move');

  static final _stylusUp = _lib.lookupFunction<
      Void Function(Pointer<Void>, Double, Double, Double),
      void Function(Pointer<Void>, double, double, double)>('cobble_engine_stylus_up');

  // Rendering
  static final _render = _lib.lookupFunction<
      Bool Function(Pointer<Void>),
      bool Function(Pointer<Void>)>('cobble_engine_render');

  static final _getPixelBuffer = _lib.lookupFunction<
      Pointer<Uint8> Function(Pointer<Void>),
      Pointer<Uint8> Function(Pointer<Void>)>('cobble_engine_get_pixel_buffer');

  static final _getBufferSize = _lib.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('cobble_engine_get_buffer_size');

  // Tool configuration
  static final _setTool = _lib.lookupFunction<
      Void Function(Pointer<Void>, Int32),
      void Function(Pointer<Void>, int)>('cobble_engine_set_tool');

  static final _setColor = _lib.lookupFunction<
      Void Function(Pointer<Void>, Uint8, Uint8, Uint8, Uint8),
      void Function(Pointer<Void>, int, int, int, int)>('cobble_engine_set_color');

  static final _setWidth = _lib.lookupFunction<
      Void Function(Pointer<Void>, Double),
      void Function(Pointer<Void>, double)>('cobble_engine_set_stroke_width');

  // High-level wrapper
  Pointer<Void> _engine = nullptr;

  void initialize(int width, int height) {
    _engine = _create(width, height);
  }

  void dispose() {
    if (_engine != nullptr) {
      _destroy(_engine);
      _engine = nullptr;
    }
  }

  void onStylusDown(double x, double y, double pressure) =>
      _stylusDown(_engine, x, y, pressure);

  void onStylusMove(double x, double y, double pressure) =>
      _stylusMove(_engine, x, y, pressure);

  void onStylusUp(double x, double y, double pressure) =>
      _stylusUp(_engine, x, y, pressure);

  /// Renders the current state and returns the pixel buffer as a ui.Image
  Future<ui.Image?> renderFrame() async {
    final changed = _render(_engine);
    if (!changed) return null;

    final bufferPtr = _getPixelBuffer(_engine);
    final bufferSize = _getBufferSize(_engine);
    final pixels = bufferPtr.asTypedList(bufferSize);

    // Zero-copy: create ui.Image directly from the native buffer
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      Uint8List.fromList(pixels), // In production, use Texture widget for true zero-copy
      width, height,
      ui.PixelFormat.bgra8888,
      completer.complete,
    );
    return completer.future;
  }
}
```

### 7.2 The Canvas Widget

```dart
// lib/ui/canvas/native_canvas_widget.dart
class NativeCanvasWidget extends StatefulWidget { ... }

class _NativeCanvasWidgetState extends State<NativeCanvasWidget>
    with SingleTickerProviderStateMixin {

  final _engine = CobbleEngineBindings();
  ui.Image? _currentFrame;
  late Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _engine.initialize(canvasWidth, canvasHeight);
    _ticker = createTicker((_) => _onTick());
    _ticker.start();
  }

  void _onTick() async {
    final frame = await _engine.renderFrame();
    if (frame != null && mounted) {
      setState(() => _currentFrame = frame);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Listener gives us raw pointer events with pressure data
      onPointerDown: (e) => _engine.onStylusDown(e.localPosition.dx, e.localPosition.dy, e.pressure),
      onPointerMove: (e) => _engine.onStylusMove(e.localPosition.dx, e.localPosition.dy, e.pressure),
      onPointerUp:   (e) => _engine.onStylusUp(e.localPosition.dx, e.localPosition.dy, e.pressure),
      child: CustomPaint(
        painter: _FramePainter(_currentFrame),
        size: Size(canvasWidth.toDouble(), canvasHeight.toDouble()),
      ),
    );
  }
}
```

---

## 8. Build System Configuration

### 8.1 Android (`android/CMakeLists.txt`)

```cmake
cmake_minimum_required(VERSION 3.18)
project(cobble_engine)

# Cairo (pre-built for Android NDK)
set(CAIRO_DIR ${CMAKE_SOURCE_DIR}/third_party/cairo-android)
include_directories(${CAIRO_DIR}/include)

# Source files extracted from Xournal++
set(ENGINE_SOURCES
    src/cobble_engine_api.cpp
    src/model/Point.cpp
    src/model/Stroke.cpp
    src/model/StrokeContour.cpp
    src/model/SplineSegment.cpp
    src/model/MathVect.cpp
    src/model/LineStyle.cpp
    src/model/Element.cpp
    src/control/StrokeHandler_Mobile.cpp
    src/control/StrokeStabilizer_Mobile.cpp
    src/view/StrokeViewHelper.cpp
    src/view/StrokeView_Mobile.cpp
)

add_library(cobble_engine SHARED ${ENGINE_SOURCES})

target_link_libraries(cobble_engine
    ${CAIRO_DIR}/lib/${ANDROID_ABI}/libcairo.a
    ${CAIRO_DIR}/lib/${ANDROID_ABI}/libpixman-1.a
    log
)

target_compile_options(cobble_engine PRIVATE
    -O3 -ffast-math -fPIC
    -DCOBBLE_MOBILE   # Preprocessor flag to disable desktop-only code paths
)
```

### 8.2 iOS (`ios/cobble_engine.podspec`)

```ruby
Pod::Spec.new do |s|
  s.name         = 'cobble_engine'
  s.version      = '1.0.0'
  s.summary      = 'Cobble C++ stroke engine'
  s.source_files = 'Classes/**/*.{h,cpp,c}'
  s.vendored_libraries = 'Libraries/libcairo.a', 'Libraries/libpixman.a'
  s.xcconfig     = { 'OTHER_CFLAGS' => '-DCOBBLE_MOBILE -O3 -ffast-math' }
  s.platform     = :ios, '13.0'
end
```

---

## 9. The Critical Algorithms Being Ported

### 9.1 Pressure-Sensitive Contour Generation (`StrokeContour.cpp`)

This is the crown jewel. Xournal++ does NOT simply draw a thick line. It generates a **filled polygon** whose width varies with pressure:

1. For each triplet of consecutive points `(p1, p2, p3)`, compute the direction vectors `v1 = p2→p1` and `v3 = p2→p3`.
2. At each joint, compute arc couplings that smoothly transition between the width of `p1.z` and `p2.z`.
3. Walk the "left side" of the stroke, then cap the end with a semicircular arc, then walk the "right side" back.
4. Fill the resulting closed polygon with `cairo_fill()`.

This produces strokes that feel like real ink—organic, smooth, with natural tapering.

### 9.2 Stroke Stabilizer Pipeline (`StrokeStabilizer.h`)

Xournal++ offers 4 stabilizer algorithms that can be mixed:

- **Deadzone:** Creates a radius around the cursor. The stroke only moves when the stylus exits this zone, eliminating hand tremor.
- **Inertia:** Simulates a spring-mass-damper system between the stylus tip and the virtual pen, producing flowing, calligraphic strokes.
- **Velocity-Gaussian:** Uses a sliding window of recent events, weighted by a Gaussian function of their velocity. Fast strokes pass through directly; slow strokes get smoothed.
- **Arithmetic Mean:** Simple sliding-window average over the last N events.

These can be combined into hybrids (e.g., `ArithmeticDeadzone`, `VelocityGaussianInertia`).

### 9.3 Width Variation Decomposition (`StrokeHandler.cpp:73-118`)

When pressure changes dramatically between two consecutive points, Xournal++ subdivides the segment into smaller steps to prevent jarring width jumps:

```
if (widthDelta > MAX_WIDTH_VARIATION) {
    nbSteps = min(ceil(abs(widthDelta) / MAX_WIDTH_VARIATION),
                  floor(distance / PIXEL_MOTION_THRESHOLD));
    // Interpolate intermediate points
}
```

This ensures buttery-smooth pressure transitions even on low-sample-rate devices.

---

## 10. Implementation Phases

### Phase 1: Proof of Concept (2-3 weeks)
- [ ] Extract core C++ files from Xournal++ into a standalone `engine/` directory
- [ ] Strip all GTK/GLib dependencies, replace with portable equivalents
- [ ] Implement `cobble_engine_api.h` C bridge
- [ ] Cross-compile Cairo as a static library for Android ARM64
- [ ] Create minimal Flutter app with `Listener` + `CustomPaint` displaying the C++ pixel buffer
- [ ] Test basic pen strokes with pressure on an Android tablet

### Phase 2: Feature Parity with Viewer (2-3 weeks)
- [ ] Implement `.xopp` file loading in the C++ engine (reuse Xournal++'s XML parser)
- [ ] Implement page navigation and zoom/scroll
- [ ] Wire up tool switching (Pen, Eraser, Highlighter)
- [ ] Implement Undo/Redo stack in C++
- [ ] Integrate with existing Flutter file browser and sync engine

### Phase 3: Production Polish (2-3 weeks)
- [ ] Optimize rendering with dirty-rectangle tracking (only re-render changed regions)
- [ ] Implement the `Texture` widget path for true GPU zero-copy on Android
- [ ] Add palm rejection using Flutter's `PointerDeviceKind` detection
- [ ] Cross-compile for iOS and test on iPad with Apple Pencil
- [ ] Integrate stabilizer settings into Flutter UI
- [ ] Performance profiling and memory leak auditing

### Phase 4: CI/CD Integration (1 week)
- [ ] Update GitHub Actions workflow to compile the C++ engine for `arm64-v8a` and `armeabi-v7a`
- [ ] Add iOS build step that compiles the engine as a static framework
- [ ] Automated APK/IPA generation with the native engine bundled

---

## 11. Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Cairo static build fails on Android NDK | Medium | Use pre-built binaries from `pkg-config` or build via Docker with NDK toolchain |
| Stylus input latency > 16ms | High | Use `Listener` (not `GestureDetector`) for raw pointer events; avoid async FFI calls on the input hot path |
| Memory leaks in C++ engine | Medium | Use ASAN (AddressSanitizer) during development; implement explicit `engine_destroy()` cleanup |
| iOS App Store rejection (C++ dynamic library) | Low | Compile as static library linked into the Runner binary (Apple allows this) |
| Cairo rendering quality differs from desktop | Low | Cairo's rendering is deterministic across platforms; use identical paint parameters |

---

## 12. Why This Approach Will Succeed

1. **Battle-tested algorithms.** We are not inventing new stroke math. We are porting algorithms that have been refined by the open-source community for over a decade.
2. **Surgical extraction.** The Xournal++ codebase has clean separation between model (`Stroke`, `Point`), view (`StrokeView`, `StrokeContour`), and control (`StrokeHandler`, `StrokeStabilizer`). This MVC architecture makes extraction feasible without touching the rest of the app.
3. **Cairo is the secret weapon.** By using Cairo as our rendering backend on both desktop AND mobile, we guarantee pixel-perfect stroke rendering parity. A stroke drawn on the Windows desktop app will look identical when viewed on the Android tablet.
4. **Flutter handles what it's good at.** UI chrome, navigation, animations, sync, file management—Flutter excels at all of this. We are only replacing the one thing it cannot do well: real-time pressure-sensitive vector rendering.
