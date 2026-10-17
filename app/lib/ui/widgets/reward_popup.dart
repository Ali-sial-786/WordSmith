import 'dart:async';

import 'package:flutter/material.dart';

import '../../net/board.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import 'game_icon.dart';

/// A quick "you got this" card for a claimed [reward]. It closes itself after
/// a moment, or on a tap.
Future<void> showRewardPopup(BuildContext context, Reward reward, {String title = 'Claimed!'}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Palette.forgeBlack.withValues(alpha: 0.5),
    transitionDuration: const Duration(milliseconds: 260),
    transitionBuilder: (context, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
        scale: Tween(begin: 0.85, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)),
        child: child,
      ),
    ),
    pageBuilder: (context, _, _) => _RewardCard(reward: reward, title: title),
  );
}

class _RewardCard extends StatefulWidget {
  const _RewardCard({required this.reward, required this.title});

  final Reward reward;
  final String title;

  @override
  State<_RewardCard> createState() => _RewardCardState();
}

class _RewardCardState extends State<_RewardCard> {
  Timer? _close;

  @override
  void initState() {
    super.initState();
    _close = Timer(const Duration(milliseconds: 1900), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _close?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = widget.reward;
    return Center(
      child: GestureDetector(
        onTap: () => Navigator.of(context).maybePop(),
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Palette.soot,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Palette.molten),
              boxShadow: [BoxShadow(color: Palette.ember.withValues(alpha: 0.35), blurRadius: 30)],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.title, textAlign: TextAlign.center, style: displayStyle(24, color: Palette.molten)),
                const SizedBox(height: 14),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 16,
                  runSpacing: 10,
                  children: [
                    if (r.xp > 0) _Item(icon: 'star', label: '+${r.xp} XP'),
                    for (final e in r.hints.entries) _Item(icon: e.key.name, label: '+${e.value} ${e.key.title}'),
                  ],
                ),
                if (r.isEmpty) Text('Nothing this time.', style: text.bodyMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.icon, required this.label});

  final String icon;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      GameIcon(icon, size: 40, color: Palette.molten),
      const SizedBox(height: 4),
      Text(label, style: Theme.of(context).textTheme.labelLarge),
    ],
  );
}

/// A reward as a row of small icons, for cards and lists.
class RewardChips extends StatelessWidget {
  const RewardChips({super.key, required this.reward, this.dim = false});

  final Reward reward;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(color: dim ? Palette.steel : Palette.whiteHeat);
    final color = dim ? Palette.steel : Palette.molten;
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (reward.xp > 0)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GameIcon('star', size: 14, color: color),
              const SizedBox(width: 3),
              Text('${reward.xp} XP', style: style),
            ],
          ),
        for (final e in reward.hints.entries)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GameIcon(e.key.name, size: 14, color: color),
              const SizedBox(width: 3),
              Text('${e.value}', style: style),
            ],
          ),
      ],
    );
  }
}
