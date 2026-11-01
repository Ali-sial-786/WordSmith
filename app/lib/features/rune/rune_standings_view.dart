import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/sfx.dart';
import '../../game/providers.dart';
import '../../game/rune_session.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/metal_button.dart';
import '../coop/emotes.dart';
import '../coop/next_round_bar.dart';
import '../coop/room_chat.dart';
import '../vs/team_widgets.dart' show teamName;
import 'rune_review.dart';
import 'rune_widgets.dart';

/// Between Rune Rush rounds (up to 30 s). First the words are counted, fast:
/// everyone's words tick in one by one with their points (a word nobody
/// else found doubled), while the list below can already be scrolled. Then
/// who took the round, the game's points so far, everyone's words and every
/// word on the grid, and the next round's countdown. After the round that
/// decided the game, the same, then on to the podium.
class RuneStandingsView extends ConsumerStatefulWidget {
  const RuneStandingsView({super.key, required this.session, required this.onLeave});

  final RuneSession session;
  final VoidCallback onLeave;

  /// The count takes about this long, however many words were found
  /// (a word at a time, a few at a time when there are lots).
  static const countTime = Duration(milliseconds: 4000);

  @override
  ConsumerState<RuneStandingsView> createState() => _RuneStandingsViewState();
}

class _RuneStandingsViewState extends ConsumerState<RuneStandingsView> {
  late final Timer _tick;

  /// The round being counted, and how many of each racer's words have been.
  int? _countingRound;
  int _counted = 0;
  int _longest = 0;
  int _perStep = 1;
  Timer? _counter;

  RuneSession get _s => widget.session;
  Sfx get _sfx => ref.read(sfxProvider);
  bool get _counting => _countingRound != null;

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
    _counter?.cancel();
    super.dispose();
  }

  /// A round that just ended here gets counted; one ended before I came back doesn't.
  void _maybeCount(RuneRoundEnd end) {
    if (_s.countRound != end.round || _countingRound == end.round) return;
    _countingRound = end.round;
    _counted = 0;
    _longest = end.found.values.fold(0, (most, list) => max(most, list.length));
    if (_longest == 0) {
      // Nothing to count (this runs while building: no setState).
      _countingRound = null;
      _finish(end, rebuild: false);
      return;
    }
    final total = RuneStandingsView.countTime.inMilliseconds;
    final stepMs = (total / _longest).clamp(60, 140).round();
    _perStep = max(1, (_longest * stepMs / total).ceil());
    _counter?.cancel();
    _counter = Timer.periodic(Duration(milliseconds: stepMs), (_) => _step(end));
  }

  void _step(RuneRoundEnd end) {
    if (!mounted || _countingRound != end.round) return;
    final from = _counted;
    setState(() => _counted = min(_longest, _counted + _perStep));
    final mine = end.found[_s.me] ?? const <RuneFoundWord>[];
    final uniqueNow = mine.skip(from).take(_counted - from).any((w) => w.unique);
    uniqueNow ? _sfx.play(SfxId.bonus, volume: 0.45) : _sfx.play(SfxId.tick, volume: 0.35);
    if (_counted >= _longest) _finish(end);
  }

  /// The count is done (or skipped): the result, and its sound.
  void _finish(RuneRoundEnd end, {bool rebuild = true}) {
    _counter?.cancel();
    _counter = null;
    if (_s.countRound == end.round) _s.countRound = null;
    _countingRound = null;
    if (rebuild && mounted) setState(() {});
    final won = end.isTeam ? end.team != null && end.team == _s.myTeam : end.winner == _s.me;
    if (end.found.containsKey(_s.me) || end.isTeam) {
      won ? _sfx.play(SfxId.roundWin) : _sfx.play(SfxId.roundLose, volume: 0.8);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final end = s.standings;
    final text = Theme.of(context).textTheme;
    if (end == null) return Center(child: CircularProgressIndicator(color: Palette.molten));
    _maybeCount(end);
    final counting = _counting;
    final next = end.next;
    final order = [
      for (final id in s.standingsOrder)
        if (s.totals.containsKey(id)) id,
    ];
    // My word being counted (or the first racer's, watching), lit on the grid.
    final focusId = end.found.containsKey(s.me) ? s.me : (end.found.keys.isEmpty ? null : end.found.keys.first);
    final focusWords = focusId == null ? const <RuneFoundWord>[] : end.found[focusId]!;
    final focus = counting && _counted > 0 && focusWords.isNotEmpty
        ? focusWords[min(_counted, focusWords.length) - 1].word
        : null;
    return Column(
      children: [
        SizedBox(
          height: 48,
          child: Row(
            children: [
              IconButton(
                onPressed: widget.onLeave,
                icon: Icon(Icons.close, color: Palette.steel),
              ),
              Expanded(
                child: Text(
                  end.tiebreak ? 'Tiebreaker round' : 'Round ${end.round} of ${s.rounds}',
                  style: displayStyle(16, color: Palette.steel),
                ),
              ),
              ChatButton(session: s, size: 20),
              EmoteButton(onEmote: s.emote, size: 20),
              const SizedBox(width: 8),
            ],
          ),
        ),
        // The count stays in view while the words below scroll.
        if (counting)
          _CountPanel(
            session: s,
            end: end,
            counted: _counted,
            onSkip: () {
              _countingRound = null;
              _finish(end);
            },
          ),
        Expanded(
          child: ListView(
            key: const ValueKey('rune-standings-list'),
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
            children: [
              if (!counting) ...[
                Text(
                  runeRoundHeadline(s, end),
                  key: const ValueKey('rune-headline'),
                  textAlign: TextAlign.center,
                  style: displayStyle(
                    24,
                    color: Palette.molten,
                  ).copyWith(shadows: [Shadow(color: Palette.ember, blurRadius: 20)]),
                ),
                const SizedBox(height: 10),
                if (s.isTeam)
                  Text(
                    'Game so far: ${teamName(0)} ${s.teamTotals[0]} · ${teamName(1)} ${s.teamTotals[1]}',
                    textAlign: TextAlign.center,
                    style: text.titleMedium,
                  )
                else
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 14,
                    runSpacing: 4,
                    children: [
                      for (final (i, id) in order.indexed)
                        Text(
                          '${i + 1}. ${id == s.me ? 'You' : s.nameOf(id)} ${s.totalOf(id)}',
                          style: text.titleSmall?.copyWith(color: s.colorOf(id)),
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
                if (next != null && end.standingsEndsAt != null) ...[
                  if (next.suddenDeath)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Tied at the top! Tiebreaker: ${runeNextLabel(s, next)}',
                        textAlign: TextAlign.center,
                        style: text.titleSmall?.copyWith(color: Palette.quenchRed),
                      ),
                    ),
                  NextRoundBar(session: s, endsAt: end.standingsEndsAt!, players: next.racers),
                ] else if (s.showingFinalRound)
                  PlateButton(
                    key: const ValueKey('rune-see-results'),
                    label: 'See the results',
                    sublabel: s.seriesEnd == null
                        ? 'Adding up the points…'
                        : 'In ${s.finalRoundLeft.inSeconds + 1} s by itself',
                    icon: 'trophy',
                    primary: true,
                    onPressed: s.seriesEnd == null ? null : s.seeResults,
                  ),
                const SizedBox(height: 16),
              ],
              RuneRoundReview(
                key: ValueKey('rune-review-${end.round}'),
                session: s,
                end: end,
                counted: counting ? _counted : null,
                focus: focus,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The count, Netflix style: each racer's latest word ticking in with its
/// points (×2 in gold when nobody else found it), their words and points
/// climbing; in Team Rune Rush the teams' points too. Skip goes to the end.
class _CountPanel extends StatelessWidget {
  const _CountPanel({required this.session, required this.end, required this.counted, required this.onSkip});

  final RuneSession session;
  final RuneRoundEnd end;
  final int counted;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final seats = [...?s.lobby?.players.map((p) => p.id)];
    int seat(String id) => seats.contains(id) ? seats.indexOf(id) : seats.length;
    final racers = end.found.keys.toList()
      ..sort((a, b) {
        if (end.isTeam) {
          final byTeam = (s.teamOf(a) ?? 0).compareTo(s.teamOf(b) ?? 0);
          if (byTeam != 0) return byTeam;
        }
        return seat(a).compareTo(seat(b));
      });
    int pointsOf(String id) => end.found[id]!.take(counted).fold(0, (sum, w) => sum + w.points);
    final teamPoints = [0, 0];
    for (final id in racers) {
      final team = s.teamOf(id);
      if (team != null) teamPoints[team] += pointsOf(id);
    }
    return Container(
      key: const ValueKey('rune-count'),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: Palette.forgeBlack.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Palette.molten.withValues(alpha: 0.6)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text("Time's up! Counting the words…", style: displayStyle(15, color: Palette.molten)),
              ),
              TextButton.icon(
                key: const ValueKey('rune-skip-count'),
                onPressed: onSkip,
                icon: const Icon(Icons.fast_forward, size: 18),
                label: const Text('Skip'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
            ],
          ),
          if (end.isTeam)
            Padding(
              padding: const EdgeInsets.only(bottom: 4, right: 6),
              child: Row(
                children: [
                  for (final team in const [0, 1])
                    Expanded(
                      child: Text(
                        '${teamName(team)}${team == s.myTeam ? ' (you)' : ''}  ${teamPoints[team]}',
                        key: ValueKey('rune-count-team-$team'),
                        textAlign: team == 0 ? TextAlign.left : TextAlign.right,
                        style: displayStyle(16, color: Palette.team(team)),
                      ),
                    ),
                ],
              ),
            ),
          for (final id in racers) _CountRow(session: s, id: id, words: end.found[id]!, counted: counted),
        ],
      ),
    );
  }
}

class _CountRow extends StatelessWidget {
  const _CountRow({required this.session, required this.id, required this.words, required this.counted});

  final RuneSession session;
  final String id;
  final List<RuneFoundWord> words;
  final int counted;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final text = Theme.of(context).textTheme;
    final shown = min(counted, words.length);
    final points = words.take(shown).fold(0, (sum, w) => sum + w.points);
    final latest = shown == 0 ? null : words[shown - 1];
    final team = s.isTeam ? s.teamOf(id) : null;
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          Container(width: 4, height: 18, color: team == null ? s.colorOf(id) : Palette.team(team)),
          const SizedBox(width: 8),
          SizedBox(
            width: 92,
            child: Text(
              id == s.me ? 'You' : s.nameOf(id),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelLarge?.copyWith(color: s.colorOf(id)),
            ),
          ),
          // The word just counted, popping in.
          Expanded(
            child: latest == null || counted > words.length
                ? Text(
                    words.isEmpty
                        ? 'no words'
                        : shown == 0
                        ? ''
                        : 'all counted',
                    style: text.labelSmall?.copyWith(color: Palette.steel),
                  )
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 90),
                    transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
                    child: Align(
                      key: ValueKey('$id-$shown'),
                      alignment: Alignment.centerLeft,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: latest.word,
                                style: letterStyle(15, color: Palette.whiteHeat),
                              ),
                              TextSpan(
                                text: latest.unique ? '  +${latest.points} ×2' : '  +${latest.points}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: latest.unique ? Palette.gold : Palette.steel,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          Text('$shown', style: text.labelMedium?.copyWith(color: Palette.steel)),
          const SizedBox(width: 10),
          SizedBox(
            width: 40,
            child: Text(
              '$points',
              key: ValueKey('rune-count-points-$id'),
              textAlign: TextAlign.right,
              style: displayStyle(18, color: Palette.whiteHeat),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}
