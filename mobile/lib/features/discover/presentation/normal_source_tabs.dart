import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../data/normal_search.dart';

/// Only the titles animate inside measured slots. Strip scrolling is derived
/// directly from the page animation, including reversals during a drag.
class NormalSourceTabs extends StatefulWidget {
  const NormalSourceTabs({
    super.key,
    required this.controller,
    required this.sources,
    required this.onSelected,
  });
  final TabController controller;
  final List<SourceSearchState> sources;
  final ValueChanged<int> onSelected;

  @override
  State<NormalSourceTabs> createState() => _NormalSourceTabsState();
}

class _NormalSourceTabsState extends State<NormalSourceTabs> {
  final _scroll = ScrollController();
  late Animation<double> _animation;
  late List<double> _titleWidths, _centers;
  late double _height;
  late TextStyle _selected, _unselected;

  @override
  void initState() {
    super.initState();
    _animation = widget.controller.animation!;
    _animation.addListener(_followPage);
  }

  @override
  void didUpdateWidget(NormalSourceTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _animation.removeListener(_followPage);
      _animation = widget.controller.animation!;
      _animation.addListener(_followPage);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    _selected = theme.textTheme.titleLarge!.copyWith(
      fontSize: 21,
      height: 1.2,
      fontWeight: FontWeight.w700,
      color: theme.colorScheme.primary,
      decoration: TextDecoration.none,
    );
    _unselected = _selected.copyWith(
      fontSize: 17,
      fontWeight: FontWeight.w400,
      color: theme.colorScheme.onSurfaceVariant,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double measure(String value, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width.ceilToDouble() + 1;
      painter.dispose();
      return width;
    }

    _titleWidths = [
      for (final source in widget.sources) measure(source.name, _selected),
    ];
    _height = (scaler.scale(21) * 1.2 + 16).clamp(48, double.infinity);
    var left = 8.0;
    _centers = [];
    for (final width in _titleWidths) {
      final slot = width + 24;
      final center = left + slot / 2;
      left += slot;
      _centers.add(center);
    }
  }

  void _followPage() {
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) return;
    final position = _animation.value
        .clamp(0, _centers.length - 1.0)
        .toDouble();
    final first = position.floor(), last = position.ceil();
    final viewport = _scroll.position.viewportDimension;
    final max = _scroll.position.maxScrollExtent;
    double stop(int index) => (_centers[index] - viewport / 2).clamp(0, max);
    final target = lerpDouble(stop(first), stop(last), position - first)!;
    // One position derived from the same animation; do not restart a separate
    // scroll animation each frame or when result counts change.
    if ((_scroll.offset - target).abs() > .001) _scroll.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox(
      height: _height,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _followPage();
          });
          return false;
        },
        child: SingleChildScrollView(
          key: const Key('normal-source-strip'),
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              for (var index = 0; index < widget.sources.length; index++)
                _SourceTab(
                  key: ValueKey(
                    'normal-source-${widget.sources[index].source.id}',
                  ),
                  source: widget.sources[index],
                  controller: widget.controller,
                  index: index,
                  titleWidth: _titleWidths[index],
                  height: _height,
                  selected: _selected,
                  unselected: _unselected,
                  onTap: () => widget.onSelected(index),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _animation.removeListener(_followPage);
    _scroll.dispose();
    super.dispose();
  }
}

class _SourceTab extends StatefulWidget {
  const _SourceTab({
    super.key,
    required this.source,
    required this.controller,
    required this.index,
    required this.titleWidth,
    required this.height,
    required this.selected,
    required this.unselected,
    required this.onTap,
  });
  final SourceSearchState source;
  final TabController controller;
  final int index;
  final double titleWidth, height;
  final TextStyle selected, unselected;
  final VoidCallback onTap;

  @override
  State<_SourceTab> createState() => _SourceTabState();
}

class _SourceTabState extends State<_SourceTab> {
  late Animation<double> _animation;
  late double _weight;
  late bool _isSelected;
  @override
  void initState() {
    super.initState();
    _animation = widget.controller.animation!;
    _weight = _emphasis;
    _isSelected = widget.controller.index == widget.index;
    _animation.addListener(_animate);
    widget.controller.addListener(_animate);
  }

  double get _emphasis =>
      (1 - (_animation.value - widget.index).abs()).clamp(0, 1);
  void _animate() {
    final value = _emphasis, selected = widget.controller.index == widget.index;
    if (value == _weight && selected == _isSelected) return;
    setState(() {
      _weight = value;
      _isSelected = selected;
    });
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.titleWidth + 24,
    height: widget.height,
    child: Semantics(
      button: true,
      selected: _isSelected,
      child: InkWell(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Transform.scale(
              key: ValueKey('normal-title-scale-${widget.source.source.id}'),
              scale: lerpDouble(17 / 21, 1, _weight)!,
              alignment: Alignment.centerLeft,
              child: Text(
                widget.source.name,
                key: ValueKey('normal-title-${widget.source.source.id}'),
                maxLines: 1,
                softWrap: false,
                // Keep font strikes at one size while retaining the visual
                // 17..21 transition. Only four font weights need shaping.
                style: TextStyle.lerp(
                  widget.unselected,
                  widget.selected,
                  _weight,
                )!.copyWith(fontSize: 21),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  @override
  void dispose() {
    _animation.removeListener(_animate);
    widget.controller.removeListener(_animate);
    super.dispose();
  }
}
