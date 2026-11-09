import 'dart:ui';

import 'package:flutter/material.dart';

import 'reader_preferences.dart';

enum ReaderDockPanel { none, catalog, settings, fonts }

class ReaderDockControls extends StatelessWidget {
  const ReaderDockControls({
    super.key,
    required this.preferences,
    required this.progress,
    required this.onProgressChanged,
    required this.onPrevious,
    required this.onNext,
    required this.actions,
    this.chapterUnit = '章',
    this.progressLabel,
  });

  final ReaderPreferences preferences;
  final double progress;
  final ValueChanged<double>? onProgressChanged;
  final VoidCallback? onPrevious, onNext;
  final List<Widget> actions;
  final String chapterUnit;
  final String Function(double)? progressLabel;

  @override
  Widget build(BuildContext context) {
    final p = preferences;
    final stepStyle = TextButton.styleFrom(
      foregroundColor: p.ink,
      disabledForegroundColor: p.ink.withValues(alpha: .35),
      minimumSize: const Size(46, 40),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      textStyle: const TextStyle(fontSize: 12),
    );
    return Padding(
      key: const Key('reader-bottom-tools'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              TextButton(
                style: stepStyle,
                onPressed: onPrevious,
                child: Text('上一$chapterUnit'),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 6,
                    activeTrackColor: p.ink.withValues(alpha: .22),
                    inactiveTrackColor: p.ink.withValues(alpha: .07),
                    thumbColor: p.background,
                    trackShape: const RoundedRectSliderTrackShape(),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                  ),
                  child: Slider(
                    key: const Key('reader-progress'),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    value: progress,
                    onChanged: onProgressChanged,
                    semanticFormatterCallback: progressLabel,
                  ),
                ),
              ),
              TextButton(
                style: stepStyle,
                onPressed: onNext,
                child: Text('下一$chapterUnit'),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: actions,
          ),
        ],
      ),
    );
  }
}

class ReaderDockAction extends StatelessWidget {
  const ReaderDockAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Widget icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: Theme.of(context).colorScheme.onSurface,
      minimumSize: const Size(64, 44),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(height: 3),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    ),
  );
}

class ReaderToolbar extends StatelessWidget {
  const ReaderToolbar({
    super.key,
    required this.visible,
    required this.background,
    required this.child,
  });

  final bool visible;
  final Color background;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: ExcludeSemantics(
      excluding: !visible,
      child: AnimatedSlide(
        key: const Key('reader-toolbar-motion'),
        offset: visible ? Offset.zero : const Offset(0, -1),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        child: Material(color: background, elevation: 0, child: child),
      ),
    ),
  );
}

/// The bottom edge stays anchored while the same surface grows upward.
class ReaderDock extends StatefulWidget {
  const ReaderDock({
    super.key,
    required this.visible,
    required this.preferences,
    required this.bottom,
    required this.controls,
    this.panel,
  });
  final bool visible;
  final ReaderPreferences preferences;
  final double bottom;
  final Widget controls;
  final Widget? panel;

  @override
  State<ReaderDock> createState() => _ReaderDockState();
}

class _ReaderDockState extends State<ReaderDock> {
  Widget? _retainedPanel;

  @override
  void initState() {
    super.initState();
    _retainedPanel = widget.panel;
  }

  @override
  void didUpdateWidget(ReaderDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.panel != null || !widget.visible) {
      _retainedPanel = widget.panel;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ReaderDock(:visible, :preferences, :bottom, :controls, :panel) =
        widget;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 260);
    if (duration == Duration.zero && panel == null) _retainedPanel = null;
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        // Include the bottom gap in the moving bounds so hidden really means
        // entirely below the screen, including the shadow and expanded panel.
        child: AnimatedSlide(
          key: const Key('reader-dock-motion'),
          offset: visible ? Offset.zero : const Offset(0, 1.08),
          duration: duration,
          curve: Curves.easeInOutCubic,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(36),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .12),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                key: const Key('reader-floating-dock'),
                borderRadius: BorderRadius.circular(36),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Material(
                    color: preferences.background.withValues(alpha: .94),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(36),
                      side: BorderSide(
                        color: preferences.ink.withValues(alpha: .12),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: panel == null ? 0 : 1),
                          duration: duration,
                          curve: Curves.easeInOutCubic,
                          onEnd: () {
                            if (widget.panel == null &&
                                _retainedPanel != null) {
                              setState(() => _retainedPanel = null);
                            }
                          },
                          builder: (context, height, child) => ClipRect(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              heightFactor: height,
                              child: child,
                            ),
                          ),
                          child: _retainedPanel == null
                              ? null
                              : IgnorePointer(
                                  ignoring: panel == null,
                                  child: ExcludeSemantics(
                                    excluding: panel == null,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _retainedPanel!,
                                        Divider(
                                          height: 1,
                                          indent: 20,
                                          endIndent: 20,
                                          color: preferences.ink.withValues(
                                            alpha: .1,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                        ),
                        controls,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
