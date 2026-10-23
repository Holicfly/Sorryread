import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/bookshelf/presentation/bookshelf_page.dart';
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
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
