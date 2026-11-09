import 'dart:math' as math;

import 'package:flutter/material.dart';

abstract final class AppSpacing {
  static const page = 20.0;
  static const listInset = 10.0;
  static const gap = 16.0;
  static const radius = 20.0;
  static const maxPageWidth = 680.0;
  static const dockBottomGap = 10.0;

  static double dockBottom(
    BuildContext context, {
    double navigationInset = 0,
  }) =>
      math.max(MediaQuery.viewPaddingOf(context).bottom, navigationInset) +
      dockBottomGap;
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

/// Shared spacing and typography inside the shell's system safe area.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.child});
  final Widget child;
  static const textPadding = 10.0;

  static TextStyle titleStyle(BuildContext context) =>
      Theme.of(context).textTheme.titleLarge!.copyWith(
        fontSize: 21,
        height: 1.2,
        fontWeight: FontWeight.w700,
        decoration: TextDecoration.none,
      );

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(bottom: 12), child: child);
}

class PageHeading extends StatelessWidget {
  const PageHeading(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => PageHeader(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: PageHeader.textPadding),
      child: Semantics(
        header: true,
        child: Text(title, style: PageHeader.titleStyle(context)),
      ),
    ),
  );
}

class PageTextTab extends StatelessWidget {
  const PageTextTab({
    super.key,
    required this.label,
    this.count,
    this.singleLine = false,
    this.compact = false,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final int? count;
  final bool singleLine;
  final bool compact;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: PageHeader.textPadding),
          child: Text.rich(
            TextSpan(
              text: label,
              children: [
                if (count != null) ...[
                  const TextSpan(
                    text: ' ',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 0,
                      wordSpacing: 0,
                    ),
                  ),
                  TextSpan(
                    text: '$count',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ],
            ),
            maxLines: singleLine || compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: PageHeader.titleStyle(context).copyWith(
              fontSize: compact ? (selected ? 17 : 14) : (selected ? 21 : 17),
              height: 1.2,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              color: selected ? colors.primary : colors.onSurfaceVariant,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
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

class FeatureIconBadge extends StatelessWidget {
  const FeatureIconBadge(
    IconData this.icon, {
    super.key,
    this.size = 38,
    this.iconSize = 23,
  }) : _asset = null;
  const FeatureIconBadge.asset(
    String asset, {
    super.key,
    this.size = 38,
    this.iconSize = 23,
  }) : icon = null,
       _asset = asset;

  final IconData? icon;
  final String? _asset;
  final double size, iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(
          alpha: theme.brightness == Brightness.dark ? .13 : .065,
        ),
        borderRadius: BorderRadius.circular(size * .32),
      ),
      alignment: Alignment.center,
      child: _asset == null
          ? Icon(icon, size: iconSize, color: theme.colorScheme.primary)
          : Image.asset(
              _asset,
              width: iconSize,
              height: iconSize,
              color: theme.colorScheme.primary,
              excludeFromSemantics: true,
            ),
    );
  }
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
