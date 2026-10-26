import 'package:flutter/material.dart';

import '../../engine/heat.dart';
import '../../game/coop_session.dart';
import '../../ui/widgets/meaning_sheet.dart';
import '../../ui/mold/mold_grid.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/xp_award.dart';
import '../../ui/widgets/forge_frame.dart';
import '../solo/forged_overlay.dart' show ScrapWords;
import 'lobby_view.dart' show HeatBanner, HeatPicker;
import 'next_round_bar.dart';
import 'room_chat.dart';

/// After a round: stars, team score, MVP, everyone's points and XP (with
/// what the heat added), missed words, and the next round's heat.
class ResultsView extends StatelessWidget {
  const ResultsView({super.key, required this.session, required this.cues, required this.onLeave});

  final CoopSession session;
  final MoldCues cues;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final r = session.results!;
    final text = Theme.of(context).textTheme;
    final mine = r.xp[session.me];
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      children: [
        ChatTitle(
          session: session,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              r.completed
                  ? 'MOLD FILLED!'
                  : r.melted
                  ? 'IT MELTED!'
                  : "TIME'S UP",
              textAlign: TextAlign.center,
              style: displayStyle(
                32,
                color: r.completed ? Palette.molten : Palette.steel,
              ).copyWith(shadows: r.completed ? [Shadow(color: Palette.ember, blurRadius: 20)] : null),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: GameIcon('star', size: 40, color: i < r.stars ? Palette.molten : Palette.ash),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Team score ${r.teamScore} · ${r.filled}/${r.total} letters forged',
          textAlign: TextAlign.center,
          style: text.titleMedium,
        ),
        if (session.survival)
          Text(
            'Survival · ${r.saved} heated word${r.saved == 1 ? '' : 's'} saved',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: Palette.molten),
          ),
        if (r.mvp != null) ...[
          const SizedBox(height: 14),
          ForgePanel(
            padding: const EdgeInsets.all(12),
            gold: true,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                GameIcon('crown', size: 28, color: Palette.molten),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'Master of the Forge: ${session.nameOf(r.mvp)}',
                    style: displayStyle(17, color: Palette.molten),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        for (final p in r.players)
          Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Palette.soot,
              borderRadius: BorderRadius.circular(10),
              border: Border(left: BorderSide(color: session.colorOf(p.id), width: 5)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(session.nameOf(p.id) + (p.id == session.me ? ' (you)' : ''), style: text.titleSmall),
                      Text.rich(
                        TextSpan(
                          text: [
                            '${p.words} ${p.words == 1 ? 'word' : 'words'}',
                            if (p.bonus > 0) '${p.bonus} bonus',
                            if (p.longest.isNotEmpty) 'longest ',
                          ].join(' · '),
                          children: [
                            // Tap it for its meaning.
                            if (p.longest.isNotEmpty)
                              WidgetSpan(
                                alignment: PlaceholderAlignment.baseline,
                                baseline: TextBaseline.alphabetic,
                                child: GestureDetector(
                                  onTap: () => showMeanings(context, [p.longest]),
                                  child: Text(
                                    p.longest,
                                    style: text.bodySmall?.copyWith(
                                      color: Palette.molten,
                                      decoration: TextDecoration.underline,
                                      decorationColor: Palette.molten,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        style: text.bodySmall,
                      ),
                    ],
                  ),
                ),
                Text('${p.points}', style: displayStyle(20)),
              ],
            ),
          ),
        if (mine != null) ...[
          const SizedBox(height: 10),
          XpAwardBanner(xp: mine.xp, level: mine.level, levelUps: mine.levelUps),
          if (mine.heatBonus > 0)
            Text(
              [
                'Includes +${mine.heatBonus} for ${Heat.fromValue((session.round?.heat ?? 1).clamp(1, 6)).label}',
                if (mine.tiersAbove > 0) '${mine.tiersAbove} tier${mine.tiersAbove == 1 ? '' : 's'} above yours',
              ].join(', '),
              key: const ValueKey('heat-bonus'),
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: Palette.molten),
            ),
          if (mine.scrapHammers > 0)
            Text(
              'Scrap Bin: +${mine.scrapHammers} Hammer Strike${mine.scrapHammers == 1 ? '' : 's'}',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: Palette.verdigris),
            ),
        ],
        const SizedBox(height: 14),
        if (session.mold != null)
          SizedBox(
            height: 220,
            child: MoldGrid(
              mold: session.mold!,
              metal: MetalStyle.forChapter('iron'),
              cues: cues,
              maxCell: 34,
              onFilledTap: (c) => showMeanings(context, session.mold!.wordsAt(c)),
            ),
          ),
        if (!r.completed)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Glowing letters are the words nobody found.',
              textAlign: TextAlign.center,
              style: text.bodySmall,
            ),
          ),
        // The bonus words the team found this round; mine went to my Scrap Bin.
        if (session.bonusWords.isNotEmpty) ...[
          const SizedBox(height: 14),
          ScrapWords(
            title: 'Bonus words this round',
            words: [for (final (w, _) in session.bonusWords) w]..sort(),
            colorOf: {for (final (w, by) in session.bonusWords) w: session.colorOf(by)},
          ),
        ],
        const SizedBox(height: 18),
        if (session.lobby != null) ...[
          Text('Next round', textAlign: TextAlign.center, style: text.labelSmall),
          const SizedBox(height: 4),
          if (session.isHost)
            HeatPicker(session: session)
          else
            HeatBanner(lobby: session.lobby!, me: session.myPlayer, hostName: session.nameOf(session.lobby!.hostId)),
          const SizedBox(height: 12),
        ],
        if (session.lobby?.nextAt case final nextAt?)
          NextRoundBar(session: session, endsAt: nextAt, players: [for (final p in session.lobby!.players) p.id])
        else if (session.isHost)
          PlateButton(
            label: 'Forge again',
            sublabel: 'New puzzle, same crew',
            icon: 'anvil',
            primary: true,
            onPressed: session.again,
          )
        else
          Text(
            'Waiting for ${session.nameOf(session.lobby?.hostId)} to forge again…',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: Palette.steel),
          ),
        if (session.isHost)
          TextButton(
            key: const ValueKey('to-lobby'),
            onPressed: () => session.setMode(session.lobby?.mode ?? 'coop'),
            child: const Text('Change the mode or settings'),
          ),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: onLeave, child: const Text('Leave the forge')),
      ],
    );
  }
}
