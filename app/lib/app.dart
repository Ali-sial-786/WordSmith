import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/armory/armory_screen.dart';
import 'features/account/setup_screen.dart';
import 'features/account/sign_in_screen.dart';
import 'features/campaign/chapters_screen.dart';
import 'features/coop/room_screen.dart';
import 'features/credits/credits_screen.dart';
import 'features/daily/daily_screen.dart';
import 'features/friends/friends_screen.dart';
import 'features/hall/hall_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/solo/puzzle_screen.dart';
import 'game/account.dart';
import 'game/daily_game.dart';
import 'net/push.dart';
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
    GoRoute(path: '/armory', builder: (_, _) => const ArmoryScreen()),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
    GoRoute(path: '/credits', builder: (_, _) => const CreditsScreen()),
    GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
    GoRoute(path: '/setup', builder: (_, _) => const SetupScreen()),
    GoRoute(path: '/friends', builder: (_, _) => const FriendsScreen()),
    GoRoute(path: '/daily', builder: (_, _) => const DailyScreen()),
    GoRoute(
      path: '/room/:code',
      builder: (_, state) => RoomScreen(
        key: ValueKey(state.pathParameters['code']),
        code: state.pathParameters['code']!.toUpperCase(),
        mode: state.uri.queryParameters['mode'] == 'vs' ? 'vs' : 'coop',
      ),
    ),
  ],
);

class WordsmithApp extends ConsumerStatefulWidget {
  const WordsmithApp({super.key, this.router});

  /// Overridden in tests; defaults to the app router.
  final GoRouter? router;

  @override
  ConsumerState<WordsmithApp> createState() => _WordsmithAppState();
}

class _WordsmithAppState extends ConsumerState<WordsmithApp> with WidgetsBindingObserver {
  StreamSubscription<Map<String, dynamic>>? _opened;

  GoRouter get _router => widget.router ?? appRouter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A tapped invite notification opens that room.
    final push = ref.read(pushServiceProvider);
    push.initialOpen().then(_openInvite);
    _opened = push.opened.listen(_openInvite);
  }

  void _openInvite(Map<String, dynamic>? data) {
    final target = inviteTarget(data);
    if (target == null || !mounted) return;
    final path = _router.routerDelegate.currentConfiguration.uri.path;
    if (path == '/room/${target.code}') return; // already there
    final location = '/room/${target.code}?mode=${target.mode}';
    // In another room: switch rooms (go replaces it, so it leaves cleanly).
    path.startsWith('/room/') ? _router.go(location) : _router.push(location);
  }

  @override
  void dispose() {
    _opened?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Catch up on anything finished offline when the player comes back.
    ref.read(accountProvider.notifier).sync();
    // A new UTC day means a new Daily Commission.
    final daily = ref.read(dailyProvider).value;
    if (daily != null && daily.date != todayUtc()) ref.invalidate(dailyProvider);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(accountProvider); // keep the account alive for the whole app
    return MaterialApp.router(
      title: 'Wordsmith',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: _router,
    );
  }
}
