import 'dart:ui';

import 'package:flutter/material.dart';

import 'reader_preferences.dart';

enum ReaderDockPanel { none, catalog, settings, fonts }

/// The bottom edge stays anchored while the same surface grows upward.
class ReaderDock extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 260);
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
                    child: AnimatedSize(
                      duration: duration,
                      curve: Curves.easeInOutCubic,
                      alignment: Alignment.bottomCenter,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (panel != null) ...[
                            panel!,
                            Divider(
                              height: 1,
                              indent: 20,
                              endIndent: 20,
                              color: preferences.ink.withValues(alpha: .1),
                            ),
                          ],
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
      ),
    );
  }
}
