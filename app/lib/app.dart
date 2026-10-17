import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'features/campaign/chapters_screen.dart';
import 'features/credits/credits_screen.dart';
import 'features/hall/hall_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/solo/puzzle_screen.dart';
import 'ui/theme/theme.dart';

final GoRouter appRouter = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => const HallScreen()),
    GoRoute(path: '/chapters', builder: (_, _) => const ChaptersScreen()),
    GoRoute(
      path: '/play/:stage',
      builder: (_, state) => PuzzleScreen(
        key: ValueKey(state.pathParameters['stage']),
        stage: int.parse(state.pathParameters['stage']!),
      ),
    ),
    GoRoute(path: '/profile', builder: (_, _) => const ProfileScreen()),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
    GoRoute(path: '/credits', builder: (_, _) => const CreditsScreen()),
  ],
);

class WordsmithApp extends StatelessWidget {
  const WordsmithApp({super.key, this.router});

  /// Overridden in tests; defaults to the app router.
  final GoRouter? router;

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Wordsmith',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    routerConfig: router ?? appRouter,
  );
}
