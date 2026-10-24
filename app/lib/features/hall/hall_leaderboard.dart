import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../game/account.dart';
import '../../game/names.dart';
import '../../net/models.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/forge_frame.dart';
import '../../ui/widgets/game_icon.dart';

/// The Forge Hall's look at the friends leaderboard: the top three by XP,
/// and my own place if I'm further down, with the whole board a tap away.
/// Nothing while it can't be fetched.
class HallLeaderboard extends ConsumerWidget {
  const HallLeaderboard({super.key});

  /// Places shown before mine.
  static const top = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(leaderboardProvider).value;
    if (entries == null) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final names = ref.watch(displayNamesProvider);
    final shown = entries.take(top).toList();
    final me = entries.where((e) => e.me).firstOrNull;
    final meBelow = me != null && !shown.contains(me);
    return ForgePanel(
      key: const ValueKey('hall-leaderboard'),
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GameIcon('trophy', size: 20, color: Palette.molten),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Leaderboard', style: displayStyle(18, color: Palette.molten)),
              ),
              TextButton(
                onPressed: () => context.push('/friends?tab=leaderboard'),
                child: Text(entries.length <= 1 ? 'Add friends' : 'See all'),
              ),
            ],
          ),
          for (final e in shown) _Row(entry: e, name: e.me ? 'You' : names.of(e.player.id, e.player.username)),
          if (meBelow) ...[
            Center(
              child: Text('⋯', style: text.labelLarge?.copyWith(color: Palette.steel)),
            ),
            _Row(entry: me, name: 'You'),
          ],
          if (entries.length <= 1)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 8),
              child: Text('Add friends to see how you stack up.', style: text.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.entry, required this.name});

  final LeaderboardEntry entry;
  final String name;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      key: ValueKey('hall-leaderboard-${entry.player.id}'),
      margin: const EdgeInsets.only(top: 4, right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: entry.me ? Palette.ember.withValues(alpha: 0.15) : null,
        borderRadius: BorderRadius.circular(10),
        border: entry.me ? Border.all(color: Palette.molten.withValues(alpha: 0.7)) : null,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text('${entry.place}', style: displayStyle(17, color: Palette.molten)),
          ),
          AvatarBadge(avatar: entry.player.avatar, size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
          ),
          Text('Lv ${entry.player.level}', style: text.labelMedium?.copyWith(color: Palette.steel)),
          const SizedBox(width: 10),
          Text('${entry.totalXp} XP', style: text.labelLarge),
        ],
      ),
    );
  }
}
