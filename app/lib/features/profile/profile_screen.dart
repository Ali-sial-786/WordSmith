import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/hints.dart';
import '../../engine/progression.dart';
import '../../game/providers.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/xp_bar.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(profileProvider);
    final campaign = ref.watch(campaignProvider);
    final progress = p.progress;
    final text = Theme.of(context).textTheme;
    final nextRank = Rank.values.where((r) => r.minLevel > progress.level).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text('Profile', style: displayStyle(22)), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(child: Text(p.rank.title, style: displayStyle(28, color: Palette.molten))),
          Center(child: Text('Smith Level ${progress.level}', style: text.titleMedium)),
          const SizedBox(height: 14),
          XpBar(fraction: progress.fraction, height: 12),
          const SizedBox(height: 6),
          Text(
            '${progress.xpIntoLevel} / ${progress.xpForNext} XP to Level ${progress.level + 1}'
            '${nextRank == null ? '' : ' · ${nextRank.title} at Level ${nextRank.minLevel}'}',
            style: text.bodySmall,
          ),
          const SizedBox(height: 24),
          Text('Hints', style: text.titleMedium),
          const SizedBox(height: 8),
          for (final k in HintKind.values)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: GameIcon(k.unlockedAt(progress.level) ? k.name : 'lock', color: Palette.molten),
              title: Text(k.title),
              subtitle: Text(_hintBlurb(k)),
              trailing: Text(
                k.unlockedAt(progress.level) ? '${p.hintCount(k)}' : 'Lv ${k.unlockLevel}',
                style: displayStyle(18),
              ),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const GameIcon('scrap_bucket', color: Palette.verdigris),
            title: const Text('Scrap Bin'),
            subtitle: Text('Every $scrapBinCapacity bonus words become a Hammer Strike'),
            trailing: Text('${p.scrapBin}/$scrapBinCapacity', style: displayStyle(18)),
          ),
          const SizedBox(height: 16),
          Text('Records', style: text.titleMedium),
          const SizedBox(height: 8),
          _Stat('Campaign', '${(p.campaignStage - 1).clamp(0, campaign.stageCount)} / ${campaign.stageCount} puzzles'),
          _Stat('Words forged', '${p.stats.wordsForged}'),
          _Stat('Bonus words', '${p.stats.bonusWords}'),
          _Stat('Longest word', p.stats.longestWord.isEmpty ? '—' : p.stats.longestWord),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Palette.soot,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Palette.ash),
            ),
            child: Text(
              'Accounts, friends, Co-op and Versus arrive in upcoming updates. '
              'Your solo progress is saved on this phone and will move to your '
              'account when you sign in.',
              style: text.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  static String _hintBlurb(HintKind k) => switch (k) {
    HintKind.hammer => 'Reveals one random letter',
    HintKind.chisel => 'Reveals the letter in a cell you pick',
    HintKind.sparks => 'Reveals up to $sparkShowerLetters letters',
  };
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        const Spacer(),
        Text(value, style: Theme.of(context).textTheme.titleSmall),
      ],
    ),
  );
}
