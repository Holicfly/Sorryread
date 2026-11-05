import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../design_system/components.dart';
import '../data/app_information.dart';

class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [Color(0xFF222B22), Color(0xFF171D19)]
              : const [Color(0xFFFBFCF5), Color(0xFFF5F3EE)],
        ),
      ),
      child: CustomPaint(
        painter: _BookPageWash(dark),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(backgroundColor: Colors.transparent),
          body: SafeArea(
            top: false,
            child: PageWidth(
              child: CustomScrollView(
                key: const Key('about-scroll'),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.listInset,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: (MediaQuery.sizeOf(context).height * .055)
                                .clamp(20, 52),
                          ),
                          Center(
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(28),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: .06),
                                    blurRadius: 30,
                                    offset: const Offset(0, 10),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                key: const Key('about-app-icon'),
                                borderRadius: BorderRadius.circular(26),
                                child: Image.asset(
                                  'assets/branding/app_mark.png',
                                  width: 104,
                                  height: 104,
                                  semanticLabel: '素若阅读应用图标',
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            '素若阅读',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineLarge?.copyWith(
                              fontSize: 28,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 3,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ref
                              .watch(appVersionProvider)
                              .when(
                                data: (value) => Text(
                                  'Ver $value',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                                loading: () => const Text(
                                  '读取版本信息…',
                                  textAlign: TextAlign.center,
                                ),
                                error: (_, _) => TextButton(
                                  onPressed: () =>
                                      ref.invalidate(appVersionProvider),
                                  child: const Text('重新读取版本信息'),
                                ),
                              ),
                          const SizedBox(height: 56),
                          SurfaceBlock(
                            padding: EdgeInsets.zero,
                            child: InkWell(
                              key: const Key('about-github'),
                              onTap: () async {
                                try {
                                  await ref
                                      .read(appInformationProvider)
                                      .openProject();
                                } catch (_) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('无法打开浏览器，请稍后重试。'),
                                      ),
                                    );
                                  }
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 22,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.code_rounded,
                                      color: theme.colorScheme.primary,
                                      size: 27,
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'GitHub 项目地址',
                                            style: theme.textTheme.titleMedium,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'Holicfly / Sorryread',
                                            style: theme.textTheme.bodySmall,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Icon(
                                      Icons.north_east_rounded,
                                      size: 19,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 48, 10, 24),
                        child: TextButton(
                          onPressed: () =>
                              context.push('/profile/about/licenses'),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.onSurfaceVariant,
                          ),
                          child: const Text('开源组件声明'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Broad paper folds pick up the warm paper and olive tones of the app icon.
class _BookPageWash extends CustomPainter {
  const _BookPageWash(this.dark);
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final strength = dark ? .12 : .35;
    final warm = Path()
      ..moveTo(-size.width * .2, size.height * .35)
      ..cubicTo(
        size.width * .15,
        -size.height * .02,
        size.width * .55,
        -size.height * .05,
        size.width * 1.1,
        size.height * .18,
      )
      ..cubicTo(
        size.width * .5,
        size.height * .01,
        size.width * .2,
        size.height * .18,
        -size.width * .2,
        size.height * .5,
      )
      ..close();
    canvas.drawPath(
      warm,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFFE2CAA4).withValues(alpha: strength),
            const Color(0xFFE2CAA4).withValues(alpha: 0),
          ],
        ).createShader(bounds),
    );
    final green = Path()
      ..moveTo(size.width * 1.1, size.height * .13)
      ..cubicTo(
        size.width * .72,
        size.height * .33,
        size.width * .68,
        size.height * .43,
        size.width * .14,
        size.height * .58,
      )
      ..cubicTo(
        size.width * .65,
        size.height * .5,
        size.width * .85,
        size.height * .42,
        size.width * 1.1,
        size.height * .32,
      )
      ..close();
    canvas.drawPath(
      green,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            const Color(0xFF9EBA97).withValues(alpha: strength),
            const Color(0xFFD8E1BE).withValues(alpha: 0),
          ],
        ).createShader(bounds),
    );
    for (var i = 0; i < 3; i++) {
      final line = Path()
        ..moveTo(size.width * .55, size.height * (.46 + i * .015))
        ..quadraticBezierTo(
          size.width * .92,
          size.height * (.35 + i * .015),
          size.width * 1.1,
          size.height * (.2 + i * .02),
        );
      canvas.drawPath(
        line,
        Paint()
          ..color = const Color(0xFF84906E).withValues(alpha: dark ? .05 : .07)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_BookPageWash oldDelegate) => oldDelegate.dark != dark;
}
