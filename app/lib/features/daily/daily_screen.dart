import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../game/account.dart';
import '../../game/daily_game.dart';
import '../../net/api_client.dart';
import '../../net/models.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/metal_button.dart';
import '../solo/puzzle_screen.dart';

/// Today's Daily Commission: the puzzle, or a "done for today" card.
class DailyScreen extends ConsumerStatefulWidget {
  const DailyScreen({super.key, this.date});

  /// An earlier day (`YYYY-MM-DD`) to play late; null for today's.
  final String? date;

  @override
  ConsumerState<DailyScreen> createState() => _DailyScreenState();
}

class _DailyScreenState extends ConsumerState<DailyScreen> {
  /// The puzzle being played. Kept for the life of this screen, so the
  /// provider refreshing after the result is sent doesn't swap it away.
  DailyInfo? _playing;

  /// Reload a puzzle from an earlier day once; after that the server's date
  /// wins (the phone's clock may be off).
  bool _refreshedStale = false;

  @override
  Widget build(BuildContext context) {
    if (_playing != null) return PuzzleScreen.daily(daily: _playing!);
    final late = widget.date != null && widget.date != todayUtc();
    final daily = late ? ref.watch(dailyForDateProvider(widget.date!)) : ref.watch(dailyProvider);
    // Loaded on an earlier day (the app stayed open past midnight UTC)?
    if (daily case AsyncData(:final value?) when !late && value.date != todayUtc() && !_refreshedStale) {
      _refreshedStale = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.invalidate(dailyProvider);
      });
      return _Frame(
        child: Center(child: CircularProgressIndicator(color: Palette.molten)),
      );
    }
    return switch (daily) {
      AsyncData(:final value?) when !value.completed => PuzzleScreen.daily(daily: _playing = value),
      AsyncData(:final value?) => _Frame(
        child: _Done(info: value, late: late),
      ),
      AsyncData() => _Frame(
        child: _Message(
          'Sign in to take on the Daily Commission.',
          action: 'Sign in',
          onPressed: () => context.push('/sign-in'),
        ),
      ),
      AsyncError(:final error) => _Frame(
        child: _Message(
          error is ApiException ? error.friendly : "Can't reach the forge right now.",
          action: 'Try again',
          onPressed: () => late ? ref.invalidate(dailyForDateProvider(widget.date!)) : ref.invalidate(dailyProvider),
        ),
      ),
      _ => _Frame(
        child: Center(child: CircularProgressIndicator(color: Palette.molten)),
      ),
    };
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      title: Text('Daily Commission', style: displayStyle(20)),
      actions: [
        IconButton(
          tooltip: 'Calendar',
          onPressed: () => context.push('/daily/calendar'),
          icon: const GameIcon('calendar', size: 24),
        ),
        IconButton(
          tooltip: "Smith's Lore",
          onPressed: () => context.push('/lore'),
          icon: const GameIcon('book', size: 24),
        ),
      ],
    ),
    extendBodyBehindAppBar: true,
    body: ForgeBackground(
      image: 'assets/images/bg_hall.webp',
      dim: 0.6,
      fire: 0.8,
      child: SafeArea(child: child),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text, {required this.action, required this.onPressed});

  final String text;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          TextButton(onPressed: onPressed, child: Text(action)),
        ],
      ),
    ),
  );
}

class _Done extends StatelessWidget {
  const _Done({required this.info, this.late = false});

  final DailyInfo info;

  /// An earlier day's commission, already done.
  final bool late;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final now = DateTime.now().toUtc();
    final midnight = DateTime.utc(now.year, now.month, now.day + 1);
    final left = midnight.difference(now);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GameIcon('flame', size: 64, color: Palette.molten),
            const SizedBox(height: 10),
            Text(late ? 'Forged!' : 'Forged for today!', style: displayStyle(28, color: Palette.molten)),
            const SizedBox(height: 8),
            Text(
              late ? "${prettyDate(info.date)}'s commission is done." : '${info.streak}-day streak · best ${info.best}',
              style: text.titleMedium,
            ),
            const SizedBox(height: 6),
            if (!late)
              Text(
                'The next commission arrives in ${left.inHours} h ${left.inMinutes % 60} min.',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: Palette.steel),
              ),
            const SizedBox(height: 22),
            PlateButton(
              label: 'Calendar',
              icon: 'calendar',
              height: 50,
              onPressed: () => context.push('/daily/calendar'),
            ),
            const SizedBox(height: 10),
            PlateButton(label: 'Forge Hall', height: 50, onPressed: () => context.go('/')),
          ],
        ),
      ),
    );
  }
}
