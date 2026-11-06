import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';

import 'book_cover.dart';

class BookOpening {
  const BookOpening(
    this.rect,
    this.design,
    this.title,
    this.progress, {
    this.decodeWidth,
    this.onClosed,
    this.coverImage,
    this.localCover,
  });
  final Rect rect;
  final int design;
  final String title, progress;
  final int? decodeWidth;
  final VoidCallback? onClosed;
  final ui.Image? coverImage;
  final File? localCover;
}

/// Lightweight transition lifecycle signal, also usable by profile tooling
/// without walking or instrumenting the widget tree during timed frames.
class BookOpeningStatus extends Notification {
  const BookOpeningStatus(this.status);
  final AnimationStatus status;
}

/// Sent after the ready body has actually painted at its final position.
class BookPaperReady extends Notification {
  const BookPaperReady({this.alreadyRasterized = false});
  final bool alreadyRasterized;
}

/// Reader-local context. Loading decorations listen to the animation without
/// rebuilding the reader, its text layout, or either transformed plane.
class BookPaperScope extends InheritedWidget {
  const BookPaperScope({
    super.key,
    required this.animation,
    required this.cloneFrozenPaper,
    required this.prepareBodyRaster,
    required super.child,
  });
  final Animation<double> animation;
  final ui.Image? Function() cloneFrozenPaper;
  final VoidCallback prepareBodyRaster;
  static BookPaperScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BookPaperScope>();
  @override
  bool updateShouldNotify(BookPaperScope oldWidget) =>
      animation != oldWidget.animation;
}

/// Freeze only the covered shelf's system-bar metrics. This prevents native
/// fullscreen changes from moving the return cell during the shared transition.
/// The actual shelf layout, scroll position and data are left intact.
class BookShelfBackdrop extends StatefulWidget {
  const BookShelfBackdrop({super.key, required this.child});
  final Widget child;
  static VoidCallback hold(BuildContext context) =>
      context.findAncestorStateOfType<_BookShelfBackdropState>()?._hold() ??
      () {};
  @override
  State<BookShelfBackdrop> createState() => _BookShelfBackdropState();
}

class _BookShelfBackdropState extends State<BookShelfBackdrop> {
  MediaQueryData? _held;
  VoidCallback _hold() {
    setState(() => _held = MediaQuery.of(context));
    return () {
      if (mounted) setState(() => _held = null);
    };
  }

  @override
  Widget build(BuildContext context) =>
      MediaQuery(data: _held ?? MediaQuery.of(context), child: widget.child);
}

/// Pure geometry, shared by frame tests and the actual composited layers.
/// Positive Y rotation makes z negative at the free edge. With positive
/// perspective this reduces homogeneous w: that edge is nearer and larger.
class BookOpeningGeometry {
  BookOpeningGeometry(this.source, this.viewport, double progress)
    : progress = progress.clamp(0, 1);
  final Rect source;
  final Size viewport;
  final double progress;
  Size get coverSize =>
      Size(viewport.height * source.width / source.height, viewport.height);
  Rect get paperRect => Rect.lerp(source, Offset.zero & viewport, progress)!;
  Matrix4 get paperTransform {
    final r = paperRect;
    return Matrix4.identity()
      ..translateByDouble(r.left, r.top, 0, 1)
      ..scaleByDouble(
        r.width / viewport.width,
        r.height / viewport.height,
        1,
        1,
      );
  }

  Matrix4 get coverTransform {
    final r = paperRect, size = coverSize;
    final perspective = Matrix4.identity()
      // Bound the maximum free-edge enlargement to 1 / .84 = 1.19.
      ..setEntry(3, 2, .16 / size.width)
      ..rotateY(math.pi / 2 * progress);
    return Matrix4.identity()
      ..translateByDouble(r.left, r.top, 0, 1)
      ..scaleByDouble(r.height / size.height, r.height / size.height, 1, 1)
      ..translateByDouble(0, size.height / 2, 0, 1)
      ..multiply(perspective)
      ..translateByDouble(0, -size.height / 2, 0, 1);
  }
}

/// Fixed-size, static cover and paper layers. Each tick changes matrices only;
/// blur, gradients, text layout, image decoding and reader loads are not animated.
class BookOpeningTransition extends StatefulWidget {
  const BookOpeningTransition({
    super.key,
    required this.opening,
    required this.animation,
    required this.child,
  });
  final BookOpening opening;
  final Animation<double> animation;
  final Widget child;
  @override
  State<BookOpeningTransition> createState() => _BookOpeningTransitionState();
}

class _BookOpeningTransitionState extends State<BookOpeningTransition> {
  late CurvedAnimation _motion;
  final _paperSnapshot = _PaperSnapshotController();
  bool _started = false, _closed = false;
  TransitionRoute<dynamic>? _route;
  VoidCallback? _onClosed;
  MediaQueryData? _readerMetrics;
  Size? _transitionViewport, _lastViewport;

  @override
  void initState() {
    super.initState();
    _onClosed = widget.opening.onClosed;
    _bind();
  }

  void _bind() {
    _motion = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    widget.animation.addStatusListener(_status);
  }

  @override
  void didUpdateWidget(BookOpeningTransition old) {
    super.didUpdateWidget(old);
    _onClosed = widget.opening.onClosed;
    if (old.animation != widget.animation) {
      old.animation.removeStatusListener(_status);
      _motion.dispose();
      _bind();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route == null &&
        route != null &&
        identical(route.animation, widget.animation)) {
      _route = route;
      // completed resolves after the overlay has gone, unlike Navigator.push.
      _route!.completed.whenComplete(_notifyClosed);
    }
  }

  void _notifyClosed() {
    if (_closed) return;
    _closed = true;
    _onClosed?.call();
  }

  void _status(AnimationStatus status) {
    _paperSnapshot.openingActive = status == AnimationStatus.forward;
    _paperSnapshot.openingPending = false;
    _paperSnapshot.closing = status == AnimationStatus.reverse;
    if (status == AnimationStatus.reverse) _transitionViewport = _lastViewport;
    if (mounted) BookOpeningStatus(status).dispatch(context);
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.reverse) {
      _started = true;
    }
    _paperSnapshot.allowSnapshotting = status == AnimationStatus.reverse;
    if (status == AnimationStatus.completed) _paperSnapshot.clear();
    if (status == AnimationStatus.dismissed && _started && _route == null) {
      _notifyClosed();
    }
  }

  void _prepareBodyRaster() {
    if (widget.animation.isCompleted ||
        widget.animation.status == AnimationStatus.reverse) {
      return;
    }
    _paperSnapshot.openingActive = true;
    _paperSnapshot.openingPending = true;
    _paperSnapshot.requestPaint?.call();
  }

  @override
  Widget build(BuildContext context) {
    final metrics = MediaQuery.of(context);
    // Keep the existing safe margins as well as typography. Native system bar
    // animation cannot relayout the paper or move its footer mid-transition.
    _readerMetrics ??= metrics;
    _transitionViewport ??= _readerMetrics!.size;
    if (widget.animation.isCompleted && !_paperSnapshot.allowSnapshotting) {
      if (metrics.size != _readerMetrics!.size ||
          metrics.textScaler != _readerMetrics!.textScaler ||
          metrics.devicePixelRatio != _readerMetrics!.devicePixelRatio) {
        _readerMetrics = metrics;
      }
      _transitionViewport = null;
    }
    final viewport = _transitionViewport ?? metrics.size;
    _lastViewport = viewport;
    final readerMetrics = _readerMetrics!;
    final plane = BookOpeningGeometry(
      widget.opening.rect,
      viewport,
      0,
    ).coverSize;
    final paper = ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: viewport.width,
        maxWidth: viewport.width,
        minHeight: viewport.height,
        maxHeight: viewport.height,
        child: SizedBox.fromSize(
          size: viewport,
          child: _FrozenPaperSurface(
            controller: _paperSnapshot,
            pixelRatio: math.min(
              MediaQuery.devicePixelRatioOf(context),
              1080 / viewport.width,
            ),
            child: ListenableBuilder(
              listenable: _paperSnapshot,
              child: BookPaperScope(
                animation: _motion,
                prepareBodyRaster: _prepareBodyRaster,
                cloneFrozenPaper: () =>
                    (_paperSnapshot.closingImage ?? _paperSnapshot.image)
                        ?.clone(),
                child: widget.child,
              ),
              builder: (_, child) => TickerMode(
                enabled: !_paperSnapshot.allowSnapshotting,
                child: MediaQuery(data: readerMetrics, child: child!),
              ),
            ),
          ),
        ),
      ),
    );
    final nativeRatio = MediaQuery.devicePixelRatioOf(context);
    final decodeWidth =
        widget.opening.decodeWidth ??
        (widget.opening.rect.width * 1024 / 858 * nativeRatio).ceil().clamp(
          1,
          1024,
        );
    final cover = RepaintBoundary(
      child: SizedBox.fromSize(
        size: plane,
        child: widget.opening.coverImage != null
            ? RawImage(
                image: widget.opening.coverImage,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.low,
              )
            : FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: widget.opening.rect.width,
                  height: widget.opening.rect.height,
                  child: BookCover(
                    localCover: widget.opening.localCover,
                    design: widget.opening.design,
                    title: widget.opening.title,
                    progress: widget.opening.progress,
                    decodeWidthOverride: decodeWidth,
                  ),
                ),
              ),
      ),
    );
    return AnimatedBuilder(
      animation: _motion,
      child: cover,
      builder: (context, staticCover) {
        final geometry = BookOpeningGeometry(
          widget.opening.rect,
          viewport,
          _motion.value,
        );
        // These same paper/cover widgets are reused on every tick. Their fixed
        // constraints do not relayout text or decode images as the book grows.
        return IgnorePointer(
          ignoring: !widget.animation.isCompleted,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: Transform(
                  key: const ValueKey('book-paper'),
                  alignment: Alignment.topLeft,
                  transform: geometry.paperTransform,
                  child: paper,
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                width: plane.width,
                height: plane.height,
                child: Transform(
                  key: const ValueKey('book-front-cover'),
                  alignment: Alignment.topLeft,
                  transform: geometry.coverTransform,
                  child: IgnorePointer(child: staticCover),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_status);
    _motion.dispose();
    _paperSnapshot.dispose();
    super.dispose();
  }
}

/// Freeze the already-painted layer, instead of SnapshotWidget repainting the
/// whole reader into a detached scene on the first closing frame.
class _FrozenPaperSurface extends SingleChildRenderObjectWidget {
  const _FrozenPaperSurface({
    required this.controller,
    required this.pixelRatio,
    required super.child,
  });
  final SnapshotController controller;
  final double pixelRatio;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _FrozenPaper(controller, pixelRatio);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _FrozenPaper renderObject,
  ) {
    renderObject.pixelRatio = pixelRatio;
  }
}

class _FrozenPaper extends RenderRepaintBoundary {
  _FrozenPaper(this.controller, this.pixelRatio);
  final SnapshotController controller;
  double pixelRatio;
  ui.Image? _frozen;
  bool _openingFrozen = false;
  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    controller.addListener(_changed);
    if (controller is _PaperSnapshotController) {
      (controller as _PaperSnapshotController).requestPaint = markNeedsPaint;
    }
  }

  @override
  void detach() {
    controller.removeListener(_changed);
    if (controller is _PaperSnapshotController) {
      (controller as _PaperSnapshotController).requestPaint = null;
    }
    super.detach();
  }

  void _changed() {
    _openingFrozen = false;
    if (controller is _PaperSnapshotController) {
      (controller as _PaperSnapshotController).image = null;
    }
    _frozen?.dispose();
    _frozen = null;
    final painted = layer;
    if (controller.allowSnapshotting &&
        hasSize &&
        !size.isEmpty &&
        painted is OffsetLayer &&
        painted.supportsRasterization()) {
      _frozen = painted.toImageSync(Offset.zero & size, pixelRatio: pixelRatio);
      if (controller is _PaperSnapshotController) {
        final snapshot = controller as _PaperSnapshotController;
        snapshot.image = _frozen;
        if (snapshot.closing) {
          // Keep a shared handle until route teardown. Dismissed clears the
          // active surface before the reader transfers ownership to its cache.
          snapshot.closingImage?.dispose();
          snapshot.closingImage = _frozen!.clone();
        }
      }
    }
    markNeedsPaint();
  }

  // Shape work has already finished in bounded batches. Record its first paint
  // in the paper's fixed coordinates, before any animated scale reaches glyphs.
  // This uses the same detached PaintingContext pattern as SDK SnapshotWidget,
  // but only for a newly ready opening body; closing still uses the painted layer.
  void _capturePreparedBody(_PaperSnapshotController snapshot) {
    snapshot.openingPending = false;
    final detached = OffsetLayer();
    final painting = PaintingContext(detached, Offset.zero & size);
    super.paint(painting, Offset.zero);
    // Same protected recording boundary used by Flutter's SnapshotWidget.
    // ignore: invalid_use_of_protected_member
    painting.stopRecordingIfNeeded();
    if (!detached.supportsRasterization()) {
      detached.dispose();
      return;
    }
    final image = detached.toImageSync(
      Offset.zero & size,
      pixelRatio: pixelRatio,
    );
    detached.dispose();
    _frozen?.dispose();
    _frozen = image;
    snapshot.image = image;
    _openingFrozen = true;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final snapshot = controller;
    if (snapshot is _PaperSnapshotController &&
        snapshot.openingActive &&
        snapshot.openingPending) {
      _capturePreparedBody(snapshot);
    }
    final image = _frozen;
    if ((controller.allowSnapshotting || _openingFrozen) && image != null) {
      context.canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        offset & size,
        Paint()..filterQuality = FilterQuality.low,
      );
    } else {
      super.paint(context, offset);
    }
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    _frozen?.dispose();
    if (controller is _PaperSnapshotController) {
      (controller as _PaperSnapshotController).image = null;
    }
    super.dispose();
  }
}

class _PaperSnapshotController extends SnapshotController {
  ui.Image? image;
  ui.Image? closingImage;
  bool closing = false;
  bool openingActive = false, openingPending = false;
  VoidCallback? requestPaint;
  @override
  void dispose() {
    closingImage?.dispose();
    closingImage = null;
    super.dispose();
  }
}
