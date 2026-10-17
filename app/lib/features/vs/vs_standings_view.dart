import 'dart:async';

import 'package:flutter/material.dart';

import '../../game/vs_session.dart';
import '../../net/room_client.dart';
import '../../ui/widgets/meaning_sheet.dart';
import '../../ui/mold/mold_grid.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../coop/emotes.dart';
import 'vs_widgets.dart';

/// The 10 seconds between Versus rounds: who won and how, the series tally,
/// and what comes next.
class VsStandingsView extends StatefulWidget {
  const VsStandingsView({super.key, required this.session, required this.cues, required this.onLeave});

  final VsSession session;
  final MoldCues cues;
  final VoidCallback onLeave;

  @override
  State<VsStandingsView> createState() => _VsStandingsViewState();
}

class _VsStandingsViewState extends State<VsStandingsView> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final end = s.standings;
    final text = Theme.of(context).textTheme;
    if (end == null) return const Center(child: CircularProgressIndicator(color: Palette.molten));
    final winner = end.winner;
    final next = end.next;
    final secs = end.standingsEndsAt == null ? 0 : ((end.standingsEndsAt! - s.serverNow) / 1000).ceil().clamp(0, 99);
    final lastFilled = {for (final p in end.progress) p.id: p};
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      children: [
        Row(
          children: [
            IconButton(onPressed: widget.onLeave, icon: const Icon(Icons.close, color: Palette.steel)),
            const Spacer(),
            EmoteButton(onEmote: s.emote),
          ],
        ),
        Text(
          roundHeadline(s, end),
          textAlign: TextAlign.center,
          style: displayStyle(28, color: winner == s.me ? Palette.molten : Palette.whiteHeat).copyWith(
            shadows: winner == s.me ? const [Shadow(color: Palette.ember, blurRadius: 20)] : null,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          switch (end.how) {
            'finished' => 'Filled the whole mold',
            'timeout' => 'Most letters when time ran out (${lastFilled[winner]?.filled ?? 0})',
            'survived' =>
              "${end.melted?.id == s.me ? 'Your' : "${s.nameOf(end.melted?.id)}'s"} heated word melted. "
                  'Most letters among the rest (${lastFilled[winner]?.filled ?? 0})',
            _ when end.melted != null => 'A heated word melted before anyone filled a letter',
            _ => 'Nobody filled a letter',
          },
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: Palette.steel),
        ),
        const SizedBox(height: 18),
        for (final id in s.standingsOrder)
          _TallyRow(
            session: s,
            id: id,
            wins: end.tally[id] ?? 0,
            filled: lastFilled[id],
            wonThis: id == winner,
          ),
        const SizedBox(height: 18),
        if (next != null) ...[
          Text(
            next.suddenDeath
                ? 'Sudden death: ${next.racers.map(s.nameOf).join(' vs ')}'
                : 'Round ${next.round} of up to ${s.series}',
            textAlign: TextAlign.center,
            style: displayStyle(18, color: next.suddenDeath ? Palette.quenchRed : Palette.molten),
          ),
          Text('Starts in $secs', textAlign: TextAlign.center, style: text.titleMedium),
          if (next.suddenDeath && !next.racers.contains(s.me))
            Text("You'll watch this one", textAlign: TextAlign.center, style: text.bodySmall),
        ],
        if (s.mold != null && s.racing) ...[
          const SizedBox(height: 16),
          SizedBox(
            height: 200,
            child: MoldGrid(
              mold: s.mold!,
              metal: MetalStyle.forChapter('steel'),
              cues: widget.cues,
              maxCell: 32,
              onFilledTap: (c) => showMeanings(context, s.mold!.wordsAt(c)),
            ),
          ),
          Text('Glowing letters are the words you missed.', textAlign: TextAlign.center, style: text.bodySmall),
        ],
      ],
    );
  }
}

class _TallyRow extends StatelessWidget {
  const _TallyRow({required this.session, required this.id, required this.wins, required this.filled, required this.wonThis});

  final VsSession session;
  final String id;
  final int wins;
  final RacerProgress? filled;
  final bool wonThis;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final player = session.lobby?.player(id);
    final color = session.colorOf(id);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: wonThis ? Palette.ember.withValues(alpha: 0.16) : Palette.soot,
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: color, width: 5)),
      ),
      child: Row(
        children: [
          Opacity(
            opacity: player == null || !player.connected ? 0.4 : 1,
            child: AvatarBadge(avatar: player?.avatar ?? 'avatar_01', size: 34),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(session.nameOf(id) + (id == session.me ? ' (you)' : ''), style: text.titleSmall),
                Text(
                  filled == null ? (player == null ? 'Left the forge' : 'Watched') : '${filled!.filled}/${filled!.total} letters',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          WinPips(wins: wins, color: color, size: 14),
          const SizedBox(width: 8),
          Text('$wins', style: displayStyle(20, color: color)),
        ],
      ),
    );
  }
}
