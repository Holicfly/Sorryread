import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/bookshelf/presentation/bookshelf_page.dart';
import '../features/bookshelf/presentation/book_opening.dart';
import '../features/discover/data/discover_repository.dart';
import '../features/discover/presentation/discover_page.dart';
import '../features/discover/presentation/normal_search_page.dart';
import '../features/reader/presentation/reader_page.dart';
import '../data/sync_repository.dart';
import '../features/profile/presentation/profile_page.dart';
import '../features/profile/presentation/edit_profile_page.dart';
import '../features/profile/presentation/about_page.dart';
import '../features/profile/presentation/component_licenses_page.dart';
import '../features/profile/presentation/reading_history_page.dart';
import '../features/profile/presentation/local_storage_page.dart';
import 'shell.dart';
import '../features/sync/presentation/sync_page.dart';
import '../features/sync/presentation/scan_pair_page.dart';

GoRoute _syncRoute() => GoRoute(
  path: 'sync',
  builder: (context, state) => const SyncPage(),
  routes: [
    GoRoute(
      path: 'records',
      builder: (context, state) => const SyncRecordsPage(),
    ),
  ],
);

final appRouterProvider = Provider<GoRouter>((ref) {
  final rootNavigatorKey = GlobalKey<NavigatorState>();
  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/bookshelf',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/bookshelf',
                pageBuilder: (context, state) => NoTransitionPage<void>(
                  key: state.pageKey,
                  child: const BookshelfPage(),
                ),
                routes: [_syncRoute()],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/discover',
                pageBuilder: (context, state) => NoTransitionPage<void>(
                  key: state.pageKey,
                  child: const DiscoverPage(),
                ),
                routes: [
                  GoRoute(
                    path: 'results',
                    builder: (context, state) =>
                        state.uri.queryParameters['mode'] == 'normal'
                        ? NormalSearchPage(
                            query: state.uri.queryParameters['q'] ?? '',
                          )
                        : DiscoverResultsPage(
                            mode: state.uri.queryParameters['mode'] == 'yeshe'
                                ? DiscoverMode.yeshe
                                : DiscoverMode.mh,
                            query: state.uri.queryParameters['q'] ?? '',
                          ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/profile',
                pageBuilder: (context, state) => NoTransitionPage<void>(
                  key: state.pageKey,
                  child: const ProfilePage(),
                ),
                routes: [
                  _syncRoute(),
                  GoRoute(
                    path: 'edit',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (context, state) => const EditProfilePage(),
                  ),
                  GoRoute(
                    path: 'storage',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (context, state) => const LocalStoragePage(),
                    routes: [
                      GoRoute(
                        path: 'downloads',
                        parentNavigatorKey: rootNavigatorKey,
                        builder: (context, state) =>
                            const LocalStoragePage(downloadsOnly: true),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'history',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (context, state) => const ReadingHistoryPage(),
                  ),
                  GoRoute(
                    path: 'about',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (context, state) => const AboutPage(),
                    routes: [
                      GoRoute(
                        path: 'licenses',
                        parentNavigatorKey: rootNavigatorKey,
                        builder: (context, state) =>
                            const ComponentLicensesPage(),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      GoRoute(path: '/scan', builder: (context, state) => const ScanPairPage()),
      GoRoute(
        path: '/reader',
        redirect: (context, state) =>
            state.extra is ShelfBook || state.extra is ReaderOpenRequest
            ? null
            : '/bookshelf',
        pageBuilder: (context, state) {
          final extra = state.extra;
          final reader = extra is ReaderOpenRequest
              ? ReaderPage(
                  book: extra.book,
                  initialChapterUrl: extra.chapterUrl,
                )
              : ReaderPage(book: extra! as ShelfBook);
          final opening = extra is ReaderOpenRequest ? extra.opening : null;
          if (opening == null) {
            return MaterialPage<void>(key: state.pageKey, child: reader);
          }
          final duration = MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 600);
          return CustomTransitionPage<void>(
            key: state.pageKey,
            opaque: false,
            transitionDuration: duration,
            reverseTransitionDuration: duration,
            child: reader,
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) =>
                    BookOpeningTransition(
                      opening: opening,
                      animation: animation,
                      child: child,
                    ),
          );
        },
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
