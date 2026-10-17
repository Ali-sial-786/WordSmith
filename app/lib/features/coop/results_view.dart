import 'package:flutter/material.dart';

import '../../game/coop_session.dart';
import '../../ui/widgets/meaning_sheet.dart';
import '../../ui/mold/mold_grid.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/xp_award.dart';
import '../../ui/widgets/forge_frame.dart';

/// After a round: stars, team score, MVP, everyone's points, missed words.
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
        Text(
          r.completed ? 'MOLD FILLED!' : "TIME'S UP",
          textAlign: TextAlign.center,
          style: displayStyle(32, color: r.completed ? Palette.molten : Palette.steel).copyWith(
            shadows: r.completed ? const [Shadow(color: Palette.ember, blurRadius: 20)] : null,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: GameIcon(
                  'star',
                  size: 40,
                  color: i < r.stars ? Palette.molten : Palette.ash,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Team score ${r.teamScore} · ${r.filled}/${r.total} letters forged',
          textAlign: TextAlign.center,
          style: text.titleMedium,
        ),
        if (r.mvp != null) ...[
          const SizedBox(height: 14),
          ForgePanel(padding: const EdgeInsets.all(12), gold: true, child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const GameIcon('crown', size: 28, color: Palette.molten),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'Master of the Forge: ${session.nameOf(r.mvp)}',
                    style: displayStyle(17, color: Palette.molten),
                  ),
                ),
              ],
            )),
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
                      Text(
                        session.nameOf(p.id) + (p.id == session.me ? ' (you)' : ''),
                        style: text.titleSmall,
                      ),
                      Text(
                        [
                          '${p.words} ${p.words == 1 ? 'word' : 'words'}',
                          if (p.bonus > 0) '${p.bonus} bonus',
                          if (p.longest.isNotEmpty) 'longest ${p.longest}',
                        ].join(' · '),
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
        const SizedBox(height: 18),
        if (session.isHost)
          PlateButton(label: 'Forge again', sublabel: 'New puzzle, same crew', icon: 'anvil', primary: true, onPressed: session.again)
        else
          Text(
            'Waiting for ${session.nameOf(session.lobby?.hostId)} to forge again…',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: Palette.steel),
          ),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: onLeave, child: const Text('Leave the forge')),
      ],
    );
  }
}
