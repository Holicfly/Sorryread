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
import 'shell.dart';
import '../features/sync/presentation/sync_page.dart';
import '../features/sync/presentation/scan_pair_page.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
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
                  GoRoute(
                    path: 'sync',
                    builder: (context, state) => const SyncPage(),
                    routes: [
                      GoRoute(
                        path: 'records',
                        builder: (context, state) => const SyncRecordsPage(),
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
