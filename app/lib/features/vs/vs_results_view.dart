import 'package:flutter/material.dart';

import '../../engine/hints.dart';
import '../../game/vs_session.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/xp_award.dart';
import 'rival_molds.dart';
import 'series_summary.dart';
import 'vs_widgets.dart';

/// The end of a Versus series: the podium, my XP and embers, the series round
/// by round with everyone's molds, and a rematch.
class VsResultsView extends StatelessWidget {
  const VsResultsView({super.key, required this.session, required this.onLeave});

  final VsSession session;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final r = session.seriesEnd!;
    final text = Theme.of(context).textTheme;
    final mine = r.xp[session.me];
    final iWon = r.winner == session.me;
    // The podium holds three; anyone sharing a place beyond that is listed.
    final top = r.podium.take(3).toList();
    final rest = r.podium.skip(3).toList();
    // An older server sends no history: the last round's molds, if this phone saw it start.
    final end = session.standings;
    final round = session.round?.round;
    final last =
        r.history.isEmpty && end != null && end.molds.isNotEmpty && round != null && (end.round ?? round) == round
        ? end
        : null;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
            children: [
              Text(
                r.winner == null
                    ? 'Series over'
                    : iWon
                    ? 'YOU WIN THE SERIES!'
                    : '${session.nameOf(r.winner)} wins the series!',
                textAlign: TextAlign.center,
                style: displayStyle(
                  26,
                  color: iWon ? Palette.molten : Palette.whiteHeat,
                ).copyWith(shadows: iWon ? const [Shadow(color: Palette.ember, blurRadius: 24)] : null),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  '${r.rounds} ${r.rounds == 1 ? 'round' : 'rounds'}',
                  if (r.early) 'clinched early',
                  if (r.forfeit) 'everyone else left',
                ].join(' · '),
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: Palette.steel),
              ),
              const SizedBox(height: 20),
              _Podium(session: session, places: top),
              for (final p in rest)
                ListTile(
                  dense: true,
                  leading: Text('${p.place}', style: displayStyle(18)),
                  title: Text(session.nameOf(p.id)),
                  trailing: Text('${p.wins} ${p.wins == 1 ? 'win' : 'wins'}'),
                ),
              if (mine != null) ...[
                const SizedBox(height: 14),
                XpAwardBanner(xp: mine.xp, level: mine.level, levelUps: mine.levelUps),
                for (final line in _extras(mine))
                  Text(
                    line,
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(color: Palette.verdigris),
                  ),
              ],
              if (r.history.isNotEmpty) ...[
                const SizedBox(height: 26),
                Text(
                  'Round by round',
                  textAlign: TextAlign.center,
                  style: displayStyle(18, color: Palette.molten),
                ),
                const SizedBox(height: 10),
                SeriesSummary(session: session, series: r),
              ] else if (last != null) ...[
                const SizedBox(height: 26),
                Text(
                  'Final round',
                  textAlign: TextAlign.center,
                  style: displayStyle(18, color: Palette.molten),
                ),
                RivalMolds(session: session, end: last, padding: const EdgeInsets.only(top: 18)),
              ],
            ],
          ),
        ),
        _Actions(session: session, onLeave: onLeave),
      ],
    );
  }

  static List<String> _extras(XpAward a) => [
    for (final e in a.pickups.entries)
      if (e.value > 0) 'Embers: +${e.value} ${HintKind.byName(e.key).title}${e.value == 1 ? '' : 's'}',
    if (a.scrapHammers > 0) 'Scrap Bin: +${a.scrapHammers} Hammer Strike${a.scrapHammers == 1 ? '' : 's'}',
  ];
}

/// Leave, and the host's rematch, kept in reach below however long the
/// series was.
class _Actions extends StatelessWidget {
  const _Actions({required this.session, required this.onLeave});

  final VsSession session;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Palette.forgeBlack.withValues(alpha: 0.55), Palette.forgeBlack.withValues(alpha: 0.9)],
        ),
        border: const Border(top: BorderSide(color: Palette.ash)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
        child: Row(
          children: [
            OutlinedButton(onPressed: onLeave, child: const Text('Leave')),
            const SizedBox(width: 12),
            Expanded(
              child: session.isHost
                  ? PlateButton(
                      label: 'Rematch',
                      sublabel: 'A new best of ${session.series}',
                      icon: 'trophy',
                      primary: true,
                      onPressed: session.again,
                    )
                  : Text(
                      'Waiting for ${session.nameOf(session.lobby?.hostId)} to start a rematch…',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(color: Palette.steel),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// First in the middle on the tallest plinth, second left, third right.
class _Podium extends StatelessWidget {
  const _Podium({required this.session, required this.places});

  final VsSession session;
  final List<PodiumPlace> places;

  @override
  Widget build(BuildContext context) {
    PodiumPlace? at(int index) => index < places.length ? places[index] : null;
    final order = [at(1), at(0), at(2)];
    const heights = [70.0, 100.0, 50.0];
    return SizedBox(
      height: 244,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 3; i++)
            Expanded(
              child: order[i] == null
                  ? const SizedBox()
                  : _Step(session: session, place: order[i]!, height: heights[i]),
            ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.session, required this.place, required this.height});

  final VsSession session;
  final PodiumPlace place;
  final double height;

  @override
  Widget build(BuildContext context) {
    final player = session.lobby?.player(place.id);
    final color = session.colorOf(place.id);
    final metal = switch (place.place) {
      1 => Palette.molten,
      2 => const Color(0xFFC0C6CC),
      _ => const Color(0xFFB0703F),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (place.place == 1) const GameIcon('crown', size: 28, color: Palette.molten),
          AvatarBadge(avatar: player?.avatar ?? 'avatar_01', size: place.place == 1 ? 58 : 46),
          const SizedBox(height: 4),
          Text(
            session.nameOf(place.id),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          WinPips(wins: place.wins, color: color, size: 12),
          const SizedBox(height: 4),
          Container(
            height: height,
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [metal, Color.lerp(metal, Palette.forgeBlack, 0.6)!],
              ),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            alignment: Alignment.topCenter,
            padding: const EdgeInsets.only(top: 6),
            child: Text('${place.place}', style: displayStyle(26, color: Palette.forgeBlack)),
          ),
        ],
      ),
    );
  }
}
