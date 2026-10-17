import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../engine/hints.dart';
import '../../game/providers.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/xp_bar.dart';

/// Home screen.
class HallScreen extends ConsumerWidget {
  const HallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final campaign = ref.watch(campaignProvider);
    final stage = profile.campaignStage;
    final finished = stage > campaign.stageCount;
    final chapter = campaign.chapterFor(finished ? campaign.stageCount : stage);
    final text = Theme.of(context).textTheme;
    final progress = profile.progress;
    return Scaffold(
      body: ForgeBackground(
        image: 'assets/images/bg_hall.webp',
        dim: 0.45,
        blur: 1.5,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: LayoutBuilder(
                builder: (context, c) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: c.maxHeight - 52),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'WORDSMITH',
                          textAlign: TextAlign.center,
                          style: displayStyle(40, color: Palette.molten)
                              .copyWith(
                                shadows: const [
                                  Shadow(color: Palette.ember, blurRadius: 28),
                                ],
                              ),
                        ),
                        Text(
                          'Forge words. Level up.',
                          textAlign: TextAlign.center,
                          style: text.titleSmall?.copyWith(
                            color: Palette.steel,
                          ),
                        ),
                        const SizedBox(height: 28),
                        _ProfileCard(
                          level: progress.level,
                          rank: profile.rank.title,
                          fraction: progress.fraction,
                          xpLabel:
                              '${progress.xpIntoLevel} / ${progress.xpForNext} XP',
                          hints: {
                            for (final k in HintKind.values)
                              k: profile.hintCount(k),
                          },
                          unlockedLevel: progress.level,
                          onTap: () => context.push('/profile'),
                        ),
                        const SizedBox(height: 22),
                        PlateButton(
                          label: finished ? 'Campaign complete' : 'Forge',
                          sublabel: finished
                              ? 'More puzzles are coming'
                              : '${chapter.name} · Puzzle ${stage - chapter.first + 1} of ${chapter.count}',
                          icon: 'anvil',
                          primary: true,
                          height: 72,
                          onPressed: finished
                              ? null
                              : () => context.push('/play/$stage'),
                        ),
                        const SizedBox(height: 12),
                        PlateButton(
                          label: 'Chapters',
                          sublabel: 'Tin to Starmetal',
                          icon: 'map',
                          onPressed: () => context.push('/chapters'),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: PlateButton(
                                label: 'Co-op',
                                sublabel: 'Coming soon',
                                icon: 'friends',
                                onPressed: null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: PlateButton(
                                label: 'Versus',
                                sublabel: 'Coming soon',
                                icon: 'trophy',
                                onPressed: null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: PlateButton(
                                label: 'Profile',
                                icon: 'user',
                                height: 50,
                                onPressed: () => context.push('/profile'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: PlateButton(
                                label: 'Settings',
                                icon: 'settings',
                                height: 50,
                                onPressed: () => context.push('/settings'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.level,
    required this.rank,
    required this.fraction,
    required this.xpLabel,
    required this.hints,
    required this.unlockedLevel,
    required this.onTap,
  });

  final int level;
  final String rank;
  final double fraction;
  final String xpLabel;
  final Map<HintKind, int> hints;
  final int unlockedLevel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Palette.soot.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF5C4733)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Palette.ash,
                    border: Border.all(color: Palette.molten, width: 2),
                  ),
                  child: Center(
                    child: Text(
                      '$level',
                      style: displayStyle(22, color: Palette.molten),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(rank, style: displayStyle(18)),
                      Text('Smith Level $level', style: text.bodySmall),
                      const SizedBox(height: 8),
                      XpBar(fraction: fraction),
                      const SizedBox(height: 4),
                      Text(xpLabel, style: text.labelSmall),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final e in hints.entries)
                  Opacity(
                    opacity: e.key.unlockedAt(unlockedLevel) ? 1 : 0.4,
                    child: Row(
                      children: [
                        GameIcon(
                          e.key.unlockedAt(unlockedLevel) ? e.key.name : 'lock',
                          size: 20,
                          color: Palette.molten,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          e.key.unlockedAt(unlockedLevel)
                              ? '${e.value}'
                              : 'Lv ${e.key.unlockLevel}',
                          style: text.labelLarge,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
