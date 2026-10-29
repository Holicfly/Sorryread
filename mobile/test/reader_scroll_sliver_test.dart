import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_scroll_sliver.dart';

void main() {
  test('indexed extents match varied block boundaries and large jumps', () {
    final heights = List.generate(4000, (i) => 20.25 + (i % 79) * 3.5);
    final index = ReaderExtentIndex(heights);
    var sum = 0.0;
    for (var i = 0; i < heights.length; i++) {
      expect(index.offsetOf(i), sum);
      expect(index.indexAt(sum + .001), i);
      if (i > 0) expect(index.indexAt(sum), i - 1);
      sum += heights[i];
    }
    expect(index.total, sum);
    expect(index.offsetOf(heights.length), sum);
    expect(index.indexAt(sum + 100), heights.length - 1);
    expect(ReaderExtentIndex([]).indexAt(0), 0);
    final rng = Random(42);
    for (var i = 0; i < 1000; i++) {
      final target = rng.nextDouble() * sum;
      final found = index.indexAt(target);
      expect(index.offsetOf(found), lessThanOrEqualTo(target));
      expect(index.offsetOf(found + 1), greaterThanOrEqualTo(target));
    }
  });
}
