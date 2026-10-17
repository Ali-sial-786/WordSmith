import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../game/providers.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/game_icon.dart';

/// One chapter's puzzles: forged ones to replay, the next one to play, and
/// the rest still locked.
class ChapterMapScreen extends ConsumerWidget {
  const ChapterMapScreen({super.key, required this.chapterId});

  final String chapterId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final campaign = ref.watch(campaignProvider);
    final stage = ref.watch(profileProvider.select((p) => p.campaignStage));
    final chapter = chapterId == campaign.master.id
        ? campaign.master
        : campaign.chapters.firstWhere((c) => c.id == chapterId, orElse: () => campaign.chapters.first);
    // The Master Forge is long: list only the puzzles reached so far.
    final count = chapter == campaign.master ? (stage - chapter.first + 1).clamp(0, chapter.count) : chapter.count;
    final metal = MetalStyle.forChapter(chapter.id);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, title: Text(chapter.name, style: displayStyle(22))),
      extendBodyBehindAppBar: true,
      body: ForgeBackground(
        image: chapterBackground(chapter.id),
        warmth: chapterWarmth(chapter.id),
        dim: 0.62,
        fire: 0.4,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  'Tap a forged puzzle to play it again, just for practice.',
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(color: Palette.steel),
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 74,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                  ),
                  itemCount: count,
                  itemBuilder: (context, i) {
                    final s = chapter.first + i;
                    final done = s < stage;
                    final current = s == stage;
                    return Semantics(
                      button: done || current,
                      label: 'Puzzle ${i + 1}${done ? ', forged' : current ? ', next' : ', locked'}',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: done
                            ? () => context.push('/replay/$s')
                            : current
                            ? () => context.push('/play/$s')
                            : null,
                        child: Ink(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            gradient: done
                                ? LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [metal.highlight, metal.base, Color.lerp(metal.base, Colors.black, 0.4)!],
                                  )
                                : null,
                            color: done ? null : Palette.soot.withValues(alpha: current ? 0.95 : 0.6),
                            border: Border.all(
                              color: current ? Palette.molten : Palette.ash,
                              width: current ? 2.5 : 1,
                            ),
                            boxShadow: [if (current) BoxShadow(color: Palette.ember.withValues(alpha: 0.5), blurRadius: 14)],
                          ),
                          child: Center(
                            child: done || current
                                ? Text(
                                    '${i + 1}',
                                    style: displayStyle(20, color: done ? metal.letter : Palette.molten),
                                  )
                                : const GameIcon('lock', size: 18, color: Palette.ash),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
