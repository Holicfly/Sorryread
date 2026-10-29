import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'reader_layout.dart';

/// Immutable prefix sums: viewport lookup must not scan every preceding block.
class ReaderExtentIndex {
  ReaderExtentIndex(Iterable<double> heights) {
    for (final height in heights) {
      assert(height.isFinite && height > 0);
      offsets.add(offsets.last + height);
    }
  }

  final offsets = <double>[0];
  int get length => offsets.length - 1;
  double get total => offsets.last;
  double offsetOf(int index) => offsets[index.clamp(0, length)];
  double? extentAt(int index, SliverLayoutDimensions _) =>
      index >= 0 && index < length ? offsets[index + 1] - offsets[index] : null;

  int indexAt(double pixels) {
    if (pixels <= 0 || length == 0) return 0;
    var lo = 1, hi = offsets.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (offsets[mid] < pixels) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    // Include the preceding block at an exact boundary, like the framework's
    // varied-extent sliver, to avoid rounding gaps during reverse scrolling.
    return math.min(lo - 1, length - 1);
  }
}

class ReaderScrollSliver extends SliverMultiBoxAdaptorWidget {
  ReaderScrollSliver({super.key, required List<ReaderBlock> blocks})
    : index = ReaderExtentIndex(blocks.map((b) => b.height)),
      super(
        delegate: SliverChildBuilderDelegate(
          (context, i) => Semantics(
            label: blocks[i].plainText,
            child: CustomPaint(painter: BlockPainter(blocks[i])),
          ),
          childCount: blocks.length,
          addAutomaticKeepAlives: false,
        ),
      );

  final ReaderExtentIndex index;

  @override
  RenderReaderSliver createRenderObject(BuildContext context) =>
      RenderReaderSliver(
        childManager: context as SliverMultiBoxAdaptorElement,
        index: index,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderReaderSliver renderObject,
  ) {
    renderObject.index = index;
  }
}

class RenderReaderSliver extends RenderSliverVariedExtentList {
  RenderReaderSliver({
    required super.childManager,
    required ReaderExtentIndex index,
  }) : _index = index,
       super(itemExtentBuilder: index.extentAt);

  ReaderExtentIndex _index;
  set index(ReaderExtentIndex value) {
    _index = value;
    itemExtentBuilder = value.extentAt;
  }

  @override
  double indexToLayoutOffset(double itemExtent, int index) =>
      _index.offsetOf(index);
  @override
  int getMinChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _index.indexAt(scrollOffset);
  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _index.indexAt(scrollOffset);
  @override
  double computeMaxScrollOffset(
    SliverConstraints constraints,
    double itemExtent,
  ) => _index.total;
  @override
  double estimateMaxScrollOffset(
    SliverConstraints constraints, {
    int? firstIndex,
    int? lastIndex,
    double? leadingScrollOffset,
    double? trailingScrollOffset,
  }) => _index.total;
}
