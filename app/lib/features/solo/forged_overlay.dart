import 'package:flutter/material.dart';

import '../../data/campaign.dart';
import '../../engine/hints.dart';
import '../../engine/pickups.dart';
import '../../engine/progression.dart';
import '../../game/providers.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/xp_bar.dart';

enum ForgedAction { next, hall }

Future<ForgedAction> showForgedOverlay(
  BuildContext context, {
  required CompletionReward reward,
  required Chapter chapter,
  required Chapter? nextChapter,
  required List<Pickup> pickups,
  required int bonusWords,
}) async {
  final result = await showGeneralDialog<ForgedAction>(
    context: context,
    barrierDismissible: false,
    barrierColor: Palette.forgeBlack.withValues(alpha: 0.72),
    transitionDuration: const Duration(milliseconds: 380),
    transitionBuilder: (context, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
        scale: Tween(begin: 0.9, end: 1.0).animate(
          CurvedAnimation(parent: a, curve: Curves.easeOutBack),
        ),
        child: child,
      ),
    ),
    pageBuilder: (context, _, _) => _ForgedCard(
      reward: reward,
      chapter: chapter,
      nextChapter: nextChapter,
      pickups: pickups,
      bonusWords: bonusWords,
    ),
  );
  return result ?? ForgedAction.hall;
}

class _ForgedCard extends StatefulWidget {
  const _ForgedCard({
    required this.reward,
    required this.chapter,
    required this.nextChapter,
    required this.pickups,
    required this.bonusWords,
  });

  final CompletionReward reward;
  final Chapter chapter;
  final Chapter? nextChapter;
  final List<Pickup> pickups;
  final int bonusWords;

  @override
  State<_ForgedCard> createState() => _ForgedCardState();
}

class _ForgedCardState extends State<_ForgedCard> with SingleTickerProviderStateMixin {
  late final AnimationController _bar = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) _bar.forward();
    });
  }

  @override
  void dispose() {
    _bar.dispose();
    super.dispose();
  }

  /// XP bar position over the animation: fills to the end of the old level
  /// first if the player levelled up, then fills the new level.
  (int, double) _barAt(double t) {
    final r = widget.reward;
    if (!r.leveledUp) {
      final from = r.before.fraction;
      final to = r.after.fraction;
      return (r.after.level, from + (to - from) * t);
    }
    if (t < 0.5) {
      return (r.before.level, r.before.fraction + (1 - r.before.fraction) * t * 2);
    }
    return (r.after.level, r.after.fraction * (t - 0.5) * 2);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.reward;
    final text = Theme.of(context).textTheme;
    final chapterDone = r.chapterFinished;
    final campaignDone = widget.nextChapter == null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 380),
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
            decoration: BoxDecoration(
              color: Palette.soot,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFF8C6B47), width: 2),
              boxShadow: [
                BoxShadow(color: Palette.ember.withValues(alpha: 0.35), blurRadius: 40),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'FORGED!',
                  style: displayStyle(40, color: Palette.molten).copyWith(
                    shadows: const [Shadow(color: Palette.ember, blurRadius: 24)],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  chapterDone
                      ? '${widget.chapter.name} chapter complete!'
                      : '${widget.chapter.name} puzzle forged',
                  style: text.titleSmall?.copyWith(color: Palette.steel),
                ),
                const SizedBox(height: 20),
                Text('+${r.xp} XP', style: displayStyle(26)),
                if (widget.bonusWords > 0)
                  Text(
                    'includes +${r.xp - 10} for bonus words',
                    style: text.bodySmall,
                  ),
                const SizedBox(height: 14),
                AnimatedBuilder(
                  animation: _bar,
                  builder: (context, _) {
                    final (level, fraction) = _barAt(Curves.easeInOut.transform(_bar.value));
                    return Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Smith Level $level',
                                overflow: TextOverflow.ellipsis,
                                style: text.labelLarge,
                              ),
                            ),
                            Text(
                              Rank.forLevel(level).title,
                              style: text.labelMedium?.copyWith(color: Palette.molten),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        XpBar(fraction: fraction, height: 12),
                      ],
                    );
                  },
                ),
                if (r.leveledUp) ...[
                  const SizedBox(height: 18),
                  _Banner(
                    title: 'LEVEL UP!',
                    lines: [
                      'You reached Smith Level ${r.after.level}.',
                      if (Rank.forLevel(r.after.level) != Rank.forLevel(r.before.level))
                        'New rank: ${Rank.forLevel(r.after.level).title}!',
                      for (final k in r.unlocked) '${k.title} unlocked!',
                    ],
                    rewards: r.hints,
                  ),
                ],
                if (widget.pickups.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const GameIcon('ember', size: 20, color: Palette.molten),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Embers found: ${widget.pickups.map((p) => p.kind.title).join(', ')}',
                          style: text.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ],
                if (chapterDone && !campaignDone) ...[
                  const SizedBox(height: 14),
                  Text(
                    'Next chapter: ${widget.nextChapter!.name}',
                    style: text.titleMedium?.copyWith(color: Palette.molten),
                  ),
                ],
                if (campaignDone) ...[
                  const SizedBox(height: 14),
                  Text(
                    'You have forged the whole campaign. More puzzles are coming!',
                    textAlign: TextAlign.center,
                    style: text.titleMedium?.copyWith(color: Palette.molten),
                  ),
                ],
                const SizedBox(height: 24),
                if (!campaignDone)
                  PlateButton(
                    label: 'Next puzzle',
                    icon: 'anvil',
                    primary: true,
                    onPressed: () => Navigator.of(context).pop(ForgedAction.next),
                  ),
                const SizedBox(height: 10),
                PlateButton(
                  label: 'Forge Hall',
                  height: 48,
                  onPressed: () => Navigator.of(context).pop(ForgedAction.hall),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.title, required this.lines, required this.rewards});

  final String title;
  final List<String> lines;
  final Map<HintKind, int> rewards;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Palette.ember.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Palette.ember.withValues(alpha: 0.6)),
      ),
      child: Column(
        children: [
          Text(title, style: displayStyle(22, color: Palette.molten)),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(l, textAlign: TextAlign.center, style: text.bodyMedium),
            ),
          if (rewards.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 6,
              children: [
                for (final e in rewards.entries)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GameIcon(e.key.name, size: 18, color: Palette.molten),
                      const SizedBox(width: 4),
                      Text('+${e.value} ${e.key.title}', style: text.labelMedium),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
