import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/sfx.dart';
import '../../game/account.dart';
import '../../game/forge_board.dart';
import '../../game/providers.dart';
import '../../net/api_client.dart';
import '../../net/board.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/reward_popup.dart';
import '../../ui/widgets/xp_bar.dart';
import '../../ui/widgets/forge_frame.dart';

/// Daily Stoke, Work Orders, Gifts and the Weekly Trials.
class BoardScreen extends ConsumerStatefulWidget {
  const BoardScreen({super.key});

  @override
  ConsumerState<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends ConsumerState<BoardScreen> {
  /// What's being claimed or sent, so its button waits.
  String? _busy;

  @override
  void initState() {
    super.initState();
    // Progress may have moved since the Hall loaded it.
    Future.microtask(() => ref.read(forgeBoardProvider.notifier).refresh());
  }

  Future<void> _run(String what, Future<Reward?> Function(ForgeBoardController c) action, {String? title}) async {
    if (_busy != null) return;
    setState(() => _busy = what);
    try {
      final reward = await action(ref.read(forgeBoardProvider.notifier));
      if (!mounted) return;
      if (reward != null) {
        ref.read(sfxProvider).play(SfxId.claim);
        await showRewardPopup(context, reward, title: title ?? 'Claimed!');
      }
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.friendly)));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(forgeBoardProvider);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('Forge Board', style: displayStyle(22)),
      ),
      extendBodyBehindAppBar: true,
      body: ForgeBackground(
        image: 'assets/images/bg_hall.webp',
        dim: 0.7,
        fire: 0.6,
        child: SafeArea(
          child: switch (board) {
            AsyncValue(:final value?) => RefreshIndicator(
              color: Palette.molten,
              onRefresh: () => ref.read(forgeBoardProvider.notifier).refresh(),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  _StokeCard(
                    stoke: value.stoke,
                    busy: _busy == 'stoke',
                    onClaim: () => _run('stoke', (c) => c.claimStoke(), title: 'The forge roars!'),
                  ),
                  const SizedBox(height: 16),
                  _OrdersCard(
                    orders: value.orders,
                    busy: _busy,
                    onClaim: (slot) => _run(
                      slot,
                      (c) => c.claimOrder(slot),
                      title: slot == 'chest' ? 'Ledger complete!' : 'Order filled!',
                    ),
                    onSwap: (slot) => _swap(slot),
                  ),
                  const SizedBox(height: 16),
                  _GiftsCard(
                    gifts: value.gifts,
                    busy: _busy,
                    onClaim: () => _run('gifts', (c) => c.claimGifts(), title: 'Gifts collected!'),
                    onSend: (id) => _run('send:$id', (c) async {
                      await c.sendGift(id);
                      return null;
                    }),
                  ),
                  const SizedBox(height: 16),
                  _TrialsCard(
                    trials: value.trials,
                    busy: _busy == 'trials',
                    onClaim: () => _run('trials', (c) => c.claimTrials(), title: 'Trial prize!'),
                  ),
                ],
              ),
            ),
            AsyncData() => const _Message('Sign in to use the Forge Board.'),
            AsyncError(:final error) => _Message(
              error is ApiException ? error.friendly : "Can't reach the forge right now.",
              onRetry: () => ref.invalidate(forgeBoardProvider),
            ),
            _ => const Center(child: CircularProgressIndicator(color: Palette.molten)),
          },
        ),
      ),
    );
  }

  Future<void> _swap(String slot) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Swap this order?'),
        content: const Text('You get a different order instead. You can swap one order a day.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Swap')),
        ],
      ),
    );
    if (ok != true) return;
    await _run('swap:$slot', (c) async {
      await c.swapOrder(slot);
      return null;
    });
  }
}

/// "3 h 20 min" / "2 d 5 h" until [end].
String timeLeft(DateTime end, {DateTime? now}) {
  final left = end.difference(now ?? DateTime.now().toUtc());
  if (left.isNegative) return 'a moment';
  if (left.inDays > 0) return '${left.inDays} d ${left.inHours % 24} h';
  if (left.inHours > 0) return '${left.inHours} h ${left.inMinutes % 60} min';
  return '${left.inMinutes.clamp(1, 59)} min';
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.icon, required this.title, required this.children, this.subtitle});

  final String icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ForgePanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GameIcon(icon, size: 24, color: Palette.molten),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: displayStyle(19))),
            ],
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(subtitle!, style: text.bodySmall?.copyWith(color: Palette.steel)),
            ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _StokeCard extends StatelessWidget {
  const _StokeCard({required this.stoke, required this.busy, required this.onClaim});

  final StokeInfo stoke;
  final bool busy;
  final VoidCallback onClaim;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _Panel(
      icon: 'bellows',
      title: 'Stoke the Forge',
      subtitle: 'A reward every day you visit. Day 7 is the big one.',
      children: [
        Row(
          children: [
            for (var i = 0; i < stoke.track.length; i++)
              Expanded(
                child: _StokeStep(
                  day: i + 1,
                  reward: stoke.track[i],
                  // Steps before today's are done; today's once claimed.
                  done: i + 1 < stoke.day || (i + 1 == stoke.day && stoke.claimedToday),
                  today: i + 1 == stoke.day && !stoke.claimedToday,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (stoke.claimedToday)
          Text('Stoked for today. Come back tomorrow!', textAlign: TextAlign.center, style: text.bodyMedium)
        else
          PlateButton(
            label: busy ? 'Stoking…' : 'Stoke! (Day ${stoke.day})',
            icon: 'bellows',
            primary: true,
            height: 50,
            onPressed: busy ? null : onClaim,
          ),
      ],
    );
  }
}

class _StokeStep extends StatelessWidget {
  const _StokeStep({required this.day, required this.reward, required this.done, required this.today});

  final int day;
  final Reward reward;
  final bool done;
  final bool today;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final big = day == 7;
    final icon = reward.hints.isEmpty ? 'star' : reward.hints.keys.last.name;
    return Semantics(
      label: 'Day $day: ${reward.label}${done ? ', claimed' : ''}',
      child: Column(
        children: [
          Container(
            width: big ? 44 : 38,
            height: big ? 44 : 38,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [if (today) BoxShadow(color: Palette.ember.withValues(alpha: 0.7), blurRadius: 14)],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: Opacity(
                    opacity: done ? 0.55 : 1,
                    child: Image.asset(
                      today ? 'assets/ui/round_active.png' : 'assets/ui/round.png',
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) => DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: today ? Palette.ember.withValues(alpha: 0.25) : Palette.forgeBlack,
                          border: Border.all(color: today ? Palette.molten : Palette.ash, width: 1.5),
                        ),
                      ),
                    ),
                  ),
                ),
                if (done)
                  const Icon(Icons.check, size: 20, color: Palette.verdigris)
                else
                  GameIcon(
                    icon,
                    size: big ? 20 : 16,
                    color: today
                        ? Palette.darkLetter
                        : big
                        ? Palette.gold
                        : Palette.molten,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(child: Text('Day $day', style: text.labelSmall)),
        ],
      ),
    );
  }
}

class _OrdersCard extends StatelessWidget {
  const _OrdersCard({required this.orders, required this.busy, required this.onClaim, required this.onSwap});

  final OrdersInfo orders;
  final String? busy;
  final ValueChanged<String> onClaim;
  final ValueChanged<String> onSwap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final allClaimed = orders.daily.every((o) => o.claimed);
    return _Panel(
      icon: 'scroll',
      title: 'Work Orders',
      subtitle: 'New daily orders in ${timeLeft(orders.dailyEndsAt)}.',
      children: [
        for (final o in orders.daily)
          _OrderTile(
            order: o,
            busy: busy == o.slot || busy == 'swap:${o.slot}',
            canSwap: orders.swapAvailable && !o.done && !o.claimed,
            onClaim: () => onClaim(o.slot),
            onSwap: () => onSwap(o.slot),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: ForgePanel(
            padding: const EdgeInsets.all(12),
            gold: true,
            child: Row(
              children: [
                const GameIcon('crown', size: 26, color: Palette.gold),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Smith's Ledger: fill all three", style: text.titleSmall),
                      const SizedBox(height: 2),
                      RewardChips(reward: orders.chestReward, dim: orders.chestClaimed),
                    ],
                  ),
                ),
                if (orders.chestClaimed)
                  const Icon(Icons.check_circle, color: Palette.verdigris)
                else
                  ForgeChipButton(
                    onPressed: orders.chestReady && busy == null ? () => onClaim('chest') : null,
                    label: allClaimed ? 'Open' : '${orders.daily.where((o) => o.claimed).length}/3',
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Text('This week', style: text.titleMedium),
            const Spacer(),
            Text('Ends in ${timeLeft(orders.weeklyEndsAt)}', style: text.labelSmall?.copyWith(color: Palette.steel)),
          ],
        ),
        const SizedBox(height: 6),
        for (final o in orders.weekly)
          _OrderTile(order: o, busy: busy == o.slot, canSwap: false, onClaim: () => onClaim(o.slot), onSwap: () {}),
      ],
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({
    required this.order,
    required this.busy,
    required this.canSwap,
    required this.onClaim,
    required this.onSwap,
  });

  final WorkOrder order;
  final bool busy;
  final bool canSwap;
  final VoidCallback onClaim;
  final VoidCallback onSwap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final o = order;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        o.title,
                        style: text.bodyMedium?.copyWith(
                          color: o.claimed ? Palette.steel : null,
                          decoration: o.claimed ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ),
                    if (o.friends) ...[
                      const SizedBox(width: 6),
                      const GameIcon('friends', size: 14, color: Palette.steel),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(child: XpBar(fraction: (o.progress / o.target).clamp(0.0, 1.0), height: 7)),
                    const SizedBox(width: 8),
                    Text('${o.progress.clamp(0, o.target)}/${o.target}', style: text.labelSmall),
                  ],
                ),
                const SizedBox(height: 3),
                RewardChips(reward: o.reward, dim: o.claimed),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (o.claimed)
            const Icon(Icons.check_circle, color: Palette.verdigris)
          else if (o.done)
            ForgeChipButton(onPressed: busy ? null : onClaim, label: 'Claim')
          else if (canSwap)
            IconButton(
              tooltip: 'Swap this order',
              onPressed: busy ? null : onSwap,
              icon: const GameIcon('swap', size: 22, color: Palette.steel),
            )
          else
            const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _GiftsCard extends ConsumerWidget {
  const _GiftsCard({required this.gifts, required this.busy, required this.onClaim, required this.onSend});

  final GiftsInfo gifts;
  final String? busy;
  final VoidCallback onClaim;
  final ValueChanged<String> onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final friends = ref.watch(accountProvider.select((a) => a.friends.friends));
    final left = gifts.claimLimit - gifts.claimedToday;
    return _Panel(
      icon: 'gift',
      title: 'Gifts',
      subtitle: 'Send each friend a free Hammer Strike every day. It costs you nothing.',
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                gifts.pending.isEmpty
                    ? 'No gifts waiting.'
                    : '${gifts.pending.length} waiting from '
                          '${{for (final g in gifts.pending) g.fromName}.join(', ')}',
                style: text.bodyMedium,
              ),
            ),
            ForgeChipButton(
              onPressed: gifts.canClaim && busy == null ? onClaim : null,
              label: left <= 0 && gifts.pending.isNotEmpty ? 'Tomorrow' : 'Collect',
            ),
          ],
        ),
        if (gifts.pending.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'You can collect ${gifts.claimLimit} a day ($left left today).',
              style: text.labelSmall?.copyWith(color: Palette.steel),
            ),
          ),
        const SizedBox(height: 10),
        if (friends.isEmpty)
          Text('Add friends to send them gifts.', style: text.bodySmall)
        else
          for (final f in friends)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  AvatarBadge(avatar: f.avatar, size: 34),
                  const SizedBox(width: 10),
                  Expanded(child: Text(f.username, style: text.bodyMedium)),
                  if (gifts.sentToday.contains(f.id))
                    Text('Sent', style: text.labelMedium?.copyWith(color: Palette.verdigris))
                  else
                    ForgeChipButton(
                      onPressed: busy == null ? () => onSend(f.id) : null,
                      primary: false,
                      icon: 'hammer',
                      label: busy == 'send:${f.id}' ? 'Sending…' : 'Send',
                    ),
                ],
              ),
            ),
      ],
    );
  }
}

class _TrialsCard extends StatelessWidget {
  const _TrialsCard({required this.trials, required this.busy, required this.onClaim});

  final TrialsInfo trials;
  final bool busy;
  final VoidCallback onClaim;

  static const _medals = [Palette.gold, Color(0xFFC9CED6), Color(0xFFC07A45)];

  static String _place(int n) => switch (n) {
    1 => '1st',
    2 => '2nd',
    3 => '3rd',
    _ => '${n}th',
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final last = trials.lastWeek;
    return _Panel(
      icon: 'trophy',
      title: 'Weekly Trials',
      subtitle:
          'Earn the most XP among your friends this week. The top three win prizes. '
          'Ends in ${timeLeft(trials.endsAt)}.',
      children: [
        if (last != null && last.claimable)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ForgePanel(
              padding: const EdgeInsets.all(12),
              gold: true,
              glint: true,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Last week: ${_place(last.place)} of ${last.of}!', style: text.titleSmall),
                        const SizedBox(height: 2),
                        RewardChips(reward: last.reward!),
                      ],
                    ),
                  ),
                  ForgeChipButton(onPressed: busy ? null : onClaim, label: 'Claim'),
                ],
              ),
            ),
          )
        else if (last != null && last.reward != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'Last week you placed ${_place(last.place)} of ${last.of}. Prize claimed.',
              style: text.bodySmall,
            ),
          ),
        if (trials.standings.length < 2) Text('Add friends to compete in the trials.', style: text.bodySmall),
        for (final (i, s) in trials.standings.indexed)
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: s.me ? Palette.ember.withValues(alpha: 0.14) : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: i < 3 && s.xp > 0
                      ? GameIcon('trophy', size: 20, color: _medals[i])
                      : Text('${i + 1}', textAlign: TextAlign.center, style: text.labelLarge),
                ),
                const SizedBox(width: 8),
                AvatarBadge(avatar: s.avatar, size: 30),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    s.me ? '${s.username} (you)' : s.username,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium,
                  ),
                ),
                Text('${s.xp} XP', style: text.titleSmall),
              ],
            ),
          ),
      ],
    );
  }
}
