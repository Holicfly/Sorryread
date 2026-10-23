import 'package:flutter/material.dart';

abstract final class AppSpacing {
  static const page = 20.0;
  static const gap = 16.0;
  static const radius = 20.0;
  static const maxPageWidth = 680.0;
}

class PageWidth extends StatelessWidget {
  const PageWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: AppSpacing.maxPageWidth),
      child: child,
    ),
  );
}

class PageHeading extends StatelessWidget {
  const PageHeading(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 22, 0, 24),
    child: Semantics(
      header: true,
      child: Text(title, style: Theme.of(context).textTheme.headlineLarge),
    ),
  );
}

class SurfaceBlock extends StatelessWidget {
  const SurfaceBlock({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(AppSpacing.radius),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}

class PlaceholderBadge extends StatelessWidget {
  const PlaceholderBadge({super.key, this.label = '功能占位'});
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: colors.primary)),
    );
  }
}
