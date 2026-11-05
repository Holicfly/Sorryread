import 'package:flutter/material.dart';

import '../../../design_system/components.dart';

/// A single sheet extends behind the dock; individual rows have no card fill.
class SearchResultsSurface extends StatelessWidget {
  const SearchResultsSurface({super.key, required this.child});
  final Widget child;
  static const fadeExtent = 28.0;
  static double bottomInset(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom + fadeExtent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.listInset,
      6,
      AppSpacing.listInset,
      0,
    ),
    child: Material(
      key: const Key('search-results-panel'),
      color: Theme.of(context).colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: SizedBox(
                  key: const Key('search-results-fade'),
                  height: bottomInset(context),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Theme.of(context).colorScheme.surface
                              .withValues(alpha: 0),
                          Theme.of(context).colorScheme.surface,
                          Theme.of(context).colorScheme.surface,
                        ],
                        stops: [0, fadeExtent / bottomInset(context), 1],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class SearchResultDivider extends StatelessWidget {
  const SearchResultDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Image.asset(
      'assets/reader_icons/line.png',
      width: double.infinity,
      height: 8,
      fit: BoxFit.fitWidth,
      excludeFromSemantics: true,
    ),
  );
}
