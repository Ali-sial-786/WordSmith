import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/masterwork_info.dart';
import '../../engine/hints.dart';
import '../../engine/masterworks.dart';
import '../../engine/progression.dart';
import '../../game/account.dart';
import '../../game/daily_game.dart';
import '../../game/providers.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/masterwork_art.dart';
import '../../ui/widgets/rank_badge.dart';
import '../../ui/widgets/xp_bar.dart';
import '../../ui/widgets/forge_frame.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(profileProvider);
    final campaign = ref.watch(campaignProvider);
    final progress = p.progress;
    final text = Theme.of(context).textTheme;
    final nextRank = Rank.values.where((r) => r.minLevel > progress.level).firstOrNull;
    final account = ref.watch(accountProvider);
    final server = account.server;
    final daily = ref.watch(dailyProvider).value;
    return Scaffold(
      appBar: AppBar(title: Text('Profile', style: displayStyle(22)), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(child: RankBadge(rank: p.rank, size: 72)),
          const SizedBox(height: 6),
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
          const _ArmoryCard(),
          const SizedBox(height: 16),
          Text('Records', style: text.titleMedium),
          const SizedBox(height: 8),
          _Stat('Campaign', '${(p.campaignStage - 1).clamp(0, campaign.stageCount)} / ${campaign.stageCount} puzzles'),
          if (campaign.isMaster(p.campaignStage))
            _Stat('Master Forge', '${p.campaignStage - 1 - campaign.stageCount} puzzles'),
          _Stat('Words forged', '${p.stats.wordsForged}'),
          _Stat('Bonus words', '${p.stats.bonusWords}'),
          _Stat('Longest word', p.stats.longestWord.isEmpty ? '—' : p.stats.longestWord),
          if (daily != null) ...[
            _Stat('Daily streak', '${daily.streak} ${daily.streak == 1 ? 'day' : 'days'} (best ${daily.best})'),
            if (ref.watch(dailyCalendarProvider(todayUtc().substring(0, 7))).value?.trophies case final t?)
              _Stat('Monthly trophies', '${t.gold} gold · ${t.silver} silver · ${t.bronze} bronze'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const GameIcon('book', color: Palette.molten),
              title: const Text("Smith's Lore"),
              subtitle: Text('${daily.total} ${daily.total == 1 ? 'page' : 'pages'} found'),
              trailing: const Icon(Icons.chevron_right, color: Palette.steel),
              onTap: () => context.push('/lore'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const GameIcon('calendar', color: Palette.molten),
              title: const Text('Commission calendar'),
              trailing: const Icon(Icons.chevron_right, color: Palette.steel),
              onTap: () => context.push('/daily/calendar'),
            ),
          ],
          if (server != null) ...[
            const SizedBox(height: 16),
            Text('With friends', style: text.titleMedium),
            const SizedBox(height: 8),
            _Stat('Co-op rounds', '${server.stats.coopRounds}'),
            _Stat('Master of the Forge (MVP)', '${server.stats.coopMvps}'),
            _Stat('Versus series won', '${server.stats.vsSeriesWon} of ${server.stats.vsSeries}'),
            _Stat('Versus rounds won', '${server.stats.vsRoundsWon}'),
          ] else if (account.phase != AccountPhase.unavailable) ...[
            const SizedBox(height: 24),
            ForgePanel(padding: const EdgeInsets.all(14), child: Column(
                children: [
                  Text(
                    'Sign in to keep your progress safe on every phone, and to play Co-op, '
                    'Versus and the Daily Commission with friends.',
                    style: text.bodySmall,
                  ),
                  TextButton(onPressed: () => context.push('/sign-in'), child: const Text('Sign in')),
                ],
              )),
          ],
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

/// The Masterwork being built, with a way into the Armory.
class _ArmoryCard extends ConsumerWidget {
  const _ArmoryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final progress = MasterworkProgress(ref.watch(profileProvider).masterworkPieces);
    final current = progress.current;
    final name = current == null
        ? null
        : ref.watch(masterworkInfoProvider).value?.firstWhere((i) => i.id == current.id).name;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => context.push('/armory'),
      child: Ink(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: current == null ? Palette.soot : blueprintPaper,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: current == null ? Palette.gold.withValues(alpha: 0.6) : const Color(0xFF6FA8DC)),
        ),
        child: Row(
          children: [
            MasterworkArt(
              spec: current ?? masterworkSpecs.last,
              collected: current == null ? masterworkSpecs.last.pieces : progress.piecesInCurrent,
              size: 56,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Armory', style: text.titleMedium),
                  Text(
                    current == null
                        ? 'All ${masterworkSpecs.length} Masterworks forged'
                        : '${name ?? 'Next Masterwork'}: ${progress.piecesInCurrent}/${current.pieces} pieces · '
                              '${progress.finished} forged',
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Palette.steel),
          ],
        ),
      ),
    );
  }
}
