import 'package:flutter/material.dart';

import '../../game/vs_session.dart';
import 'team_widgets.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/video_bubble.dart';
import '../../video/video_call.dart';

/// Round wins as little flames (a number past five).
class WinPips extends StatelessWidget {
  const WinPips({super.key, required this.wins, this.color, this.size = 12});

  final int wins;

  /// Molten unless given.
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? Palette.molten;
    if (wins == 0) return SizedBox(height: size);
    if (wins > 5) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_fire_department, size: size, color: color),
          Text(
            '×$wins',
            style: TextStyle(fontSize: size, color: color, fontWeight: FontWeight.w700),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [for (var i = 0; i < wins; i++) Icon(Icons.local_fire_department, size: size, color: color)],
    );
  }
}

/// The rivals across the top of a Versus round: bubble, name, wins and a live
/// bar of how full their mold is. Never their words. With video chat on, my
/// own bubble comes last, racing or watching.
class RivalStrip extends StatelessWidget {
  const RivalStrip({super.key, required this.session, this.call});

  final VsSession session;
  final VideoCall? call;

  @override
  Widget build(BuildContext context) {
    final round = session.round;
    if (round == null) return const SizedBox.shrink();
    final call = this.call;
    // Racers see their rivals; someone watching sudden death sees every racer.
    // In Team Versus, my teammates come first.
    final ids = [
      for (final id in round.racers)
        if (id != session.me) id,
    ];
    if (session.isTeam) {
      final mine = session.myTeam;
      ids.sort((a, b) => (session.teamOf(a) == mine ? 0 : 1).compareTo(session.teamOf(b) == mine ? 0 : 1));
    }
    return SizedBox(
      height: call == null ? 74 : 86,
      child: Row(
        children: [
          for (final id in ids.take(5))
            Expanded(
              child: _RivalTile(session: session, id: id, call: call),
            ),
          if (call != null)
            Align(
              alignment: Alignment.topCenter,
              child: _MyTile(session: session, call: call),
            ),
        ],
      ),
    );
  }
}

class _RivalTile extends StatelessWidget {
  const _RivalTile({required this.session, required this.id, this.call});

  final VsSession session;
  final String id;
  final VideoCall? call;

  @override
  Widget build(BuildContext context) {
    final player = session.lobby?.player(id);
    final color = session.colorOf(id);
    final progress = session.progress[id];
    final fraction = progress?.fraction ?? 0;
    final done = progress != null && progress.total > 0 && progress.filled >= progress.total;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          VideoBubble(
            userId: id,
            avatar: player?.avatar ?? 'avatar_01',
            size: call == null ? 30 : 42,
            call: call,
            color: color,
            dimmed: player != null && !player.connected,
          ),
          const SizedBox(height: 2),
          Text(
            session.nameOf(id),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // Team Versus: in their team's colour.
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: session.teamOf(id) == null || !session.isTeam ? null : Palette.team(session.teamOf(id)!),
            ),
          ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: fraction),
              duration: const Duration(milliseconds: 300),
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 6,
                color: done ? Palette.whiteHeat : color,
                backgroundColor: Palette.soot,
              ),
            ),
          ),
          const SizedBox(height: 2),
          WinPips(wins: session.tally[id] ?? 0, color: color, size: 10),
        ],
      ),
    );
  }
}

/// My own bubble in the strip: marked as me, and no bar, as my letters show
/// beside the anvil.
class _MyTile extends StatelessWidget {
  const _MyTile({required this.session, required this.call});

  final VsSession session;
  final VideoCall call;

  @override
  Widget build(BuildContext context) {
    final color = session.colorOf(session.me);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 2, 6, 2),
      // A faint line between the rivals and me.
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: Palette.ash)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          VideoBubble(
            userId: session.me,
            avatar: session.myPlayer?.avatar ?? 'avatar_01',
            size: 42,
            call: call,
            color: color,
            me: true,
          ),
          const SizedBox(height: 2),
          Text('You', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}

/// "Round 2 of up to 5", or sudden death.
String roundLabel(VsSession s) {
  final r = s.round;
  if (r == null) return '';
  if (r.suddenDeath) return 'Sudden death!';
  return 'Round ${r.regular ?? r.round} of up to ${s.series}';
}

/// The headline for a finished round.
String roundHeadline(VsSession s, VsRoundEnd end) {
  if (end.isTeam) return teamRoundHeadline(s, end);
  final winner = end.winner;
  final melted = end.melted;
  if (winner == null) {
    if (melted == null) return 'No winner this round';
    return melted.id == s.me ? 'Your word melted!' : "${s.nameOf(melted.id)}'s word melted!";
  }
  final name = winner == s.me ? 'You' : s.nameOf(winner);
  return switch (end.how) {
    'finished' => '$name forged it first!',
    'survived' => '$name ${winner == s.me ? 'survive' : 'survives'} the heat!',
    _ => '$name ${winner == s.me ? 'win' : 'wins'} on time',
  };
}

/// The big countdown before a round.
class VsCountdown extends StatelessWidget {
  const VsCountdown({super.key, required this.session});

  final VsSession session;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Palette.forgeBlack.withValues(alpha: 0.6),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            roundLabel(session),
            style: displayStyle(26, color: session.round?.suddenDeath ?? false ? Palette.quenchRed : Palette.steel),
          ),
          Text(
            '${session.countdownLeft.inSeconds + 1}',
            style: displayStyle(
              110,
              color: Palette.molten,
            ).copyWith(shadows: [Shadow(color: Palette.ember, blurRadius: 40)]),
          ),
          if (!session.racing) Text('You watch this one', style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    ),
  );
}
