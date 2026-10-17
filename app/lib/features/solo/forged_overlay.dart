import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../data/campaign.dart';
import '../../data/lore.dart';
import '../../data/masterwork_info.dart';
import '../../engine/hints.dart';
import '../../engine/masterworks.dart';
import '../../engine/pickups.dart';
import '../../engine/progression.dart';
import '../../game/providers.dart';
import '../../net/models.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/meaning_sheet.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/xp_bar.dart';
import '../../ui/widgets/forge_frame.dart';

enum ForgedAction { next, hall }

Future<ForgedAction> showForgedOverlay(
  BuildContext context, {
  required CompletionReward reward,
  required Chapter? chapter,
  required Chapter? nextChapter,
  required List<Pickup> pickups,
  required int bonusWords,
  List<String> words = const [],
  DailyOutcome? daily,
  bool dailyLate = false,
  int? lorePage,
  bool replay = false,
}) async {
  final result = await showGeneralDialog<ForgedAction>(
    context: context,
    barrierDismissible: false,
    barrierColor: Palette.forgeBlack.withValues(alpha: 0.72),
    transitionDuration: const Duration(milliseconds: 380),
    transitionBuilder: (context, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
        scale: Tween(begin: 0.9, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)),
        child: child,
      ),
    ),
    pageBuilder: (context, _, _) => _ForgedCard(
      reward: reward,
      chapter: chapter,
      nextChapter: nextChapter,
      pickups: pickups,
      bonusWords: bonusWords,
      words: words,
      daily: daily,
      dailyLate: dailyLate,
      lorePage: lorePage,
      replay: replay,
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
    this.words = const [],
    this.daily,
    this.dailyLate = false,
    this.lorePage,
    this.replay = false,
  });

  final CompletionReward reward;

  /// Null for the Daily Commission.
  final Chapter? chapter;
  final Chapter? nextChapter;
  final List<Pickup> pickups;
  final int bonusWords;

  /// The puzzle's words, to look up.
  final List<String> words;

  /// The Daily Commission's streak, when that's what was forged.
  final DailyOutcome? daily;

  /// An earlier day's commission, played late (no streak).
  final bool dailyLate;

  /// The Smith's Lore page (index) this commission unlocked.
  final int? lorePage;

  /// A replay from the chapter map: no XP, just the words.
  final bool replay;

  @override
  State<_ForgedCard> createState() => _ForgedCardState();
}

class _ForgedCardState extends State<_ForgedCard> with SingleTickerProviderStateMixin {
  late final AnimationController _bar = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

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
    final daily = widget.daily;
    final chapterDone = r.chapterFinished;
    final replay = widget.replay;
    final campaignDone = daily == null && widget.nextChapter == null && !replay;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: ForgePanel(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
              gold: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'FORGED!',
                    style: displayStyle(
                      40,
                      color: Palette.molten,
                    ).copyWith(shadows: const [Shadow(color: Palette.ember, blurRadius: 24)]),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    daily != null
                        ? (daily.alreadyDone
                              ? 'Already forged'
                              : widget.dailyLate
                              ? 'Late commission forged'
                              : 'Daily Commission forged')
                        : replay
                        ? 'Replay complete · just for practice'
                        : chapterDone
                        ? '${widget.chapter!.name} chapter complete!'
                        : '${widget.chapter!.name} puzzle forged',
                    style: text.titleSmall?.copyWith(color: Palette.steel),
                  ),
                  const SizedBox(height: 20),
                  if (!replay) ...[
                    Text('+${r.xp} XP', style: displayStyle(26)),
                    if (widget.bonusWords > 0 && daily == null)
                      Text(
                        'includes +${soloXp(bonusWords: widget.bonusWords) - soloXp(bonusWords: 0)} for bonus words',
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
                  ],
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
                  if (widget.words.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text('Tap a word to see what it means', style: text.labelMedium?.copyWith(color: Palette.steel)),
                    const SizedBox(height: 6),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final w in widget.words)
                          ActionChip(
                            label: Text(w, style: letterStyle(13)),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: Palette.ash,
                            side: BorderSide.none,
                            onPressed: () => showMeanings(context, [w]),
                          ),
                      ],
                    ),
                  ],
                  if (r.gildedPiece) ...[const SizedBox(height: 14), _MasterworkNote(reward: r)],
                  if (chapterDone && !campaignDone) ...[
                    const SizedBox(height: 14),
                    Text(
                      'Next chapter: ${widget.nextChapter!.name}',
                      style: text.titleMedium?.copyWith(color: Palette.molten),
                    ),
                  ],
                  if (daily != null && widget.dailyLate) ...[
                    const SizedBox(height: 14),
                    Text(
                      'Played late, so your streak is unchanged.',
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(color: Palette.steel),
                    ),
                  ] else if (daily != null) ...[
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const GameIcon('flame', size: 26, color: Palette.molten),
                        const SizedBox(width: 8),
                        Text('${daily.streak}-day streak', style: displayStyle(20, color: Palette.molten)),
                      ],
                    ),
                    Text(
                      daily.best > daily.streak ? 'Best: ${daily.best} days' : 'Your best yet!',
                      style: text.bodyMedium?.copyWith(color: Palette.steel),
                    ),
                    Text('A new commission arrives at midnight UTC.', style: text.bodySmall),
                  ],
                  if (widget.lorePage case final index?) ...[const SizedBox(height: 14), _LoreNote(index: index)],
                  if (campaignDone) ...[
                    const SizedBox(height: 14),
                    Text(
                      'You have forged the whole campaign. More puzzles are coming!',
                      textAlign: TextAlign.center,
                      style: text.titleMedium?.copyWith(color: Palette.molten),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (!campaignDone && daily == null && !replay)
                    PlateButton(
                      label: 'Next puzzle',
                      icon: 'anvil',
                      primary: true,
                      onPressed: () => Navigator.of(context).pop(ForgedAction.next),
                    ),
                  const SizedBox(height: 10),
                  PlateButton(
                    label: replay ? 'Back' : 'Forge Hall',
                    height: 48,
                    onPressed: () => Navigator.of(context).pop(ForgedAction.hall),
                  ),
                ],
              ),
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

/// The blueprint piece this puzzle gave, or the Masterwork it finished.
class _MasterworkNote extends ConsumerWidget {
  const _MasterworkNote({required this.reward});

  final CompletionReward reward;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final infos = ref.watch(masterworkInfoProvider).value;
    final done = reward.masterwork;
    if (done != null) {
      final info = infos?.firstWhere((i) => i.id == done.id);
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Palette.gold.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Palette.gold.withValues(alpha: 0.7)),
        ),
        child: Column(
          children: [
            Text(
              'MASTERWORK COMPLETE!',
              textAlign: TextAlign.center,
              style: displayStyle(20, color: Palette.gold),
            ),
            const SizedBox(height: 8),
            SvgPicture.asset(
              'assets/masterworks/${done.id}.svg',
              width: 72,
              height: 72,
              colorFilter: const ColorFilter.mode(Palette.gold, BlendMode.srcIn),
              placeholderBuilder: (_) => const SizedBox.square(dimension: 72),
            ),
            const SizedBox(height: 6),
            Text(info?.name ?? '', textAlign: TextAlign.center, style: text.titleMedium),
            Text('It now hangs in your Armory.', style: text.bodySmall?.copyWith(color: Palette.steel)),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 6,
              children: [
                Text('+$masterworkXp XP', style: text.labelMedium),
                for (final e in reward.masterworkHints.entries)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GameIcon(e.key.name, size: 18, color: Palette.gold),
                      const SizedBox(width: 4),
                      Text('+${e.value} ${e.key.title}', style: text.labelMedium),
                    ],
                  ),
              ],
            ),
          ],
        ),
      );
    }
    final progress = MasterworkProgress(ref.watch(profileProvider).masterworkPieces);
    final current = progress.current;
    final name = current == null ? null : infos?.firstWhere((i) => i.id == current.id).name;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const GameIcon('gilded', size: 20, color: Palette.gold),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            current == null
                ? 'Blueprint piece found!'
                : 'Blueprint piece: ${progress.piecesInCurrent}/${current.pieces}${name == null ? '' : ' for $name'}',
            style: text.bodyMedium,
          ),
        ),
      ],
    );
  }
}

/// The Smith's Lore page a commission unlocked, once the book has loaded.
class _LoreNote extends ConsumerWidget {
  const _LoreNote({required this.index});

  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pages = ref.watch(loreProvider).value;
    if (pages == null || index >= pages.length) return const SizedBox.shrink();
    final page = pages[index];
    final text = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2E241B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF8C6B47)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const GameIcon('book', size: 18, color: Palette.molten),
              const SizedBox(width: 6),
              Flexible(
                child: Text("New page of Smith's Lore", style: text.labelMedium?.copyWith(color: Palette.molten)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(page.title, style: text.titleMedium),
          const SizedBox(height: 4),
          Text(page.text, style: text.bodyMedium),
        ],
      ),
    );
  }
}
