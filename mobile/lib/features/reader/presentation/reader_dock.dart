import 'dart:ui';

import 'package:flutter/material.dart';

import 'reader_preferences.dart';

enum ReaderDockPanel { none, catalog, settings, fonts }

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
