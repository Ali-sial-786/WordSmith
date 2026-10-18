import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../game/providers.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/game_icon.dart';

/// The nine metal chapters and how far the player has got.
class ChaptersScreen extends ConsumerWidget {
  const ChaptersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final campaign = ref.watch(campaignProvider);
    final stage = ref.watch(profileProvider.select((p) => p.campaignStage));
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('Chapters', style: displayStyle(22)),
        centerTitle: true,
      ),
      extendBodyBehindAppBar: true,
      body: ForgeBackground(
        image: 'assets/images/bg_hall.webp',
        dim: 0.7,
        fire: 0.5,
        child: SafeArea(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            itemCount: campaign.chapters.length + (campaign.isMaster(stage) ? 1 : 0),
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final ch = i < campaign.chapters.length ? campaign.chapters[i] : campaign.master;
              final done = (stage - ch.first).clamp(0, ch.count);
              final locked = stage < ch.first;
              final current = ch.contains(stage);
              final metal = MetalStyle.forChapter(ch.id);
              return Opacity(
                opacity: locked ? 0.5 : 1,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: locked ? null : () => context.push('/chapters/${ch.id}'),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Palette.soot.withValues(alpha: 0.9),
                      // The chapter's own scene, darkened, once its art exists.
                      image: hasChapterScene(ch.id)
                          ? DecorationImage(
                              image: AssetImage(chapterBackground(ch.id)),
                              fit: BoxFit.cover,
                              alignment: const Alignment(0, -0.3),
                              colorFilter: ColorFilter.mode(Colors.black.withValues(alpha: 0.55), BlendMode.darken),
                            )
                          : null,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: current ? Palette.molten : const Color(0xFF5C4733),
                        width: current ? 2 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              center: const Alignment(-0.3, -0.4),
                              colors: [metal.highlight, metal.base, Color.lerp(metal.base, Colors.black, 0.5)!],
                            ),
                          ),
                          child: locked ? Center(child: GameIcon('lock', size: 20, color: Palette.forgeBlack)) : null,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(ch.name, style: displayStyle(18)),
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(
                                  value: done / ch.count,
                                  minHeight: 6,
                                  backgroundColor: Palette.ash,
                                  color: metal.base,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                ch == campaign.master
                                    ? 'Every puzzle again, at full XP · $done forged'
                                    : done == ch.count
                                    ? 'Complete'
                                    : '$done / ${ch.count} forged',
                                style: text.labelSmall,
                              ),
                            ],
                          ),
                        ),
                        if (current) ...[const SizedBox(width: 10), GameIcon('anvil', size: 26, color: Palette.molten)],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
