import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../design_system/components.dart';
import '../design_system/top_wash.dart';
import '../features/bookshelf/presentation/book_opening.dart';
import '../features/bookshelf/presentation/shelf_actions_dock.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell, required this.showDock});
  final StatefulNavigationShell shell;
  final bool showDock;

  static const _dockHeight = 64.0;
  // A larger radius is scaled down when the dock is collapsed, then grows
  // during expansion. Match the actual collapsed outline at every height.
  static const _dockCorners = BorderRadius.all(
    Radius.circular(_dockHeight / 2),
  );

  static const _washes = [
    TopWashTone.shelf,
    TopWashTone.discover,
    TopWashTone.profile,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(shelfSelectionProvider);
    final selecting = selected.isNotEmpty && shell.currentIndex == 0;
    return BookShelfBackdrop(
      child: PopScope(
        canPop: shell.currentIndex == 0 && !selecting,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (selecting) {
            ref.read(shelfSelectionProvider.notifier).clear();
          } else if (shell.currentIndex != 0) {
            shell.goBranch(0);
          }
        },
        child: Scaffold(
          extendBody: true,
          body: Stack(
            children: [
              // Full-bleed wash: it starts at the very top of the screen (the
              // SafeArea only insets the pages), like native readers do.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: TopWash(
                  tone: _washes[shell.currentIndex.clamp(0, 2)],
                  height: 220,
                ),
              ),
              SafeArea(bottom: false, child: shell),
            ],
          ),
          bottomNavigationBar:
              !showDock || MediaQuery.viewInsetsOf(context).bottom > 0
              ? null
              : Padding(
                  padding: const EdgeInsets.fromLTRB(
                    16,
                    0,
                    16,
                    AppSpacing.dockBottomGap,
                  ),
                  child: SafeArea(
                    top: false,
                    maintainBottomViewPadding: true,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: _dockCorners,
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x14000000),
                            blurRadius: 16,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        key: const Key('floating-dock'),
                        borderRadius: _dockCorners,
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface
                                  .withValues(alpha: .78),
                              borderRadius: _dockCorners,
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: .7),
                              ),
                            ),
                            child: AnimatedSize(
                              alignment: Alignment.bottomCenter,
                              curve: Curves.easeInOutCubic,
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 240),
                              child: selecting
                                  ? ShelfActionsDock(selected: selected)
                                  : NavigationBar(
                                      height: _dockHeight,
                                      elevation: 0,
                                      backgroundColor: Colors.transparent,
                                      surfaceTintColor: Colors.transparent,
                                      labelPadding: EdgeInsets.zero,
                                      selectedIndex: shell.currentIndex,
                                      onDestinationSelected: (index) {
                                        if (index != shell.currentIndex) {
                                          ref
                                              .read(
                                                shelfSelectionProvider.notifier,
                                              )
                                              .clear();
                                          shell.goBranch(index);
                                        }
                                      },
                                      destinations: const [
                                        NavigationDestination(
                                          icon: Icon(Icons.menu_book_outlined),
                                          selectedIcon: Icon(
                                            Icons.menu_book_rounded,
                                          ),
                                          label: '书架',
                                        ),
                                        NavigationDestination(
                                          icon: Icon(Icons.search_rounded),
                                          selectedIcon: Icon(
                                            Icons.search_rounded,
                                          ),
                                          label: '发现',
                                        ),
                                        NavigationDestination(
                                          icon: Icon(
                                            Icons.person_outline_rounded,
                                          ),
                                          selectedIcon: Icon(
                                            Icons.person_rounded,
                                          ),
                                          label: '我的',
                                        ),
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
      ),
    );
  }
}
