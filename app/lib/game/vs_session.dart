import 'dart:async';

import '../net/room_client.dart';
import '../ui/mold/mold_model.dart';
import 'remote_mold.dart';
import 'room_session.dart';

export 'remote_mold.dart';
export 'room_session.dart';

/// One Versus room ("Anvil Clash"): my own mold, everyone's progress (never
/// their words), the series tally, the standings between rounds and the podium.
class VsSession extends RoomSession {
  VsSession({required super.client, required super.me});

  /// My own copy of this round's puzzle.
  RemoteMold? mold;

  /// How full each racer's mold is, by user id.
  Map<String, RacerProgress> progress = {};

  /// Round wins so far, by user id.
  Map<String, int> tally = {};

  /// Team Versus: the teams' round wins so far, as `[copper, cobalt]`.
  List<int> teamTally = const [0, 0];

  /// The last round's result, shown between rounds.
  VsRoundEnd? standings;
  SeriesEnd? seriesEnd;

  /// Bonus words found this round (they go to the Scrap Bin).
  int bonusWords = 0;

  /// Rivals already announced as nearly done this round.
  final Set<String> _closeCalls = {};

  /// How long the round that decides the series stays up before the podium,
  /// once any melt has played: its card, then time to look at everyone's
  /// mold. "See the results" moves on sooner.
  static const finalRoundHold = Duration(seconds: 10);

  /// Until when the round that decided the series shows by itself (this
  /// phone's clock); null once that's over or the player has moved on.
  DateTime? finalRoundUntil;
  Timer? _finalRoundDone;

  /// The standings are of the round that decided the series.
  bool get finalRound => standings != null && standings!.next == null;

  /// The round that decided the series is still showing, everyone's molds and
  /// all: the podium waits for the hold (or "See the results"), and for the
  /// series' results to arrive.
  bool get showingFinalRound => finalRound && (finalRoundUntil != null || seriesEnd == null);

  /// How long until the podium shows by itself.
  Duration get finalRoundLeft {
    final left = finalRoundUntil?.difference(DateTime.now()) ?? Duration.zero;
    return left.isNegative ? Duration.zero : left;
  }

  /// Best of this many rounds.
  int get series => round?.series ?? lobby?.series ?? 3;

  /// Racing this round (in sudden death, the rest watch).
  bool get racing => round?.racers.contains(me) ?? false;

  /// A Team Versus room: two teams, Copper (0) and Cobalt (1).
  bool get isTeam => lobby?.isTeam ?? false;

  /// [id]'s team: the series' while one is on, else the lobby's.
  int? teamOf(String id) => round?.teams[id] ?? standings?.teams[id] ?? lobby?.player(id)?.team;

  int? get myTeam => teamOf(me);

  /// How Team Versus rounds are won: `combined` (letters added up) or
  /// `first` (first to fill their mold).
  String get rule => round?.rule ?? lobby?.rule ?? 'combined';

  /// Team Versus, live: each team's letters this round, added up over its
  /// racers, as `[copper, cobalt]`.
  List<int> get teamLetters {
    final sums = [0, 0];
    for (final p in progress.values) {
      final team = teamOf(p.id);
      if (team != null) sums[team] += p.filled;
    }
    return sums;
  }

  /// Team Versus, live: the letters each team's best racer has filled.
  List<int> get teamBest {
    final best = [0, 0];
    for (final p in progress.values) {
      final team = teamOf(p.id);
      if (team != null && p.filled > best[team]) best[team] = p.filled;
    }
    return best;
  }

  /// Team Versus: how many of this round's racers are on each team.
  List<int> get teamRacers {
    final n = [0, 0];
    for (final id in round?.racers ?? const <String>[]) {
      final team = teamOf(id);
      if (team != null) n[team]++;
    }
    return n;
  }

  /// The round has been decided; boards freeze until the next one.
  bool get roundOver => standings != null && round != null && phase != 'countdown';

  /// Letters I filled: the answers shown once the round is over don't count.
  int get myFilled => mold?.cells.where((c) => mold!.fillOf(c) == CellFill.filled).length ?? 0;
  int get total => mold?.cells.length ?? 0;

  /// Racers in tally order (most wins first), then the rest of the room.
  List<String> get standingsOrder {
    final ids = <String>{...tally.keys, ...?lobby?.players.map((p) => p.id)}.toList();
    ids.sort((a, b) => (tally[b] ?? 0).compareTo(tally[a] ?? 0));
    return ids;
  }

  @override
  String? departedName(String id) {
    for (final p in seriesEnd?.podium ?? const <PodiumPlace>[]) {
      if (p.id == id && p.username.isNotEmpty) return p.username;
    }
    return null;
  }

  void _beginRound(RoundStart start) {
    round = start;
    standings = null;
    seriesEnd = null;
    _endFinalRound();
    bonusWords = 0;
    _closeCalls.clear();
    feed.clear();
    mold = RemoteMold(start, () => lobby!, initials: false);
    final total = mold!.cells.length;
    // Watching: empty molds to fill as the racers' PROGRESS comes with their slots.
    progress = {for (final id in start.racers) id: RacerProgress(id, 0, total, slots: racing ? null : const [])};
    tally = {...start.tally};
    teamTally = start.teamTally ?? const [0, 0];
    syncClock(start.serverNow);
  }

  void _claim(int slot, String word) => mold?.claim(slot, word, me);

  /// The series was decided by this round: keep it up, after any melt still
  /// playing, before the podium.
  void _holdFinalRound() {
    finalRoundUntil = (melting ? melt!.until : DateTime.now()).add(finalRoundHold);
    _finalRoundDone?.cancel();
    _finalRoundDone = Timer(finalRoundLeft, seeResults);
  }

  void _endFinalRound() {
    finalRoundUntil = null;
    _finalRoundDone?.cancel();
  }

  @override
  void handle(RoomEvent e) {
    switch (e) {
      case RoundStart():
        _beginRound(e);
      case WordResult(:final result, :final slot, :final word, :final auto) when result == 'claimed' && slot != null:
        _claim(slot, word);
        for (final (s, w) in auto) {
          _claim(s, w);
        }
      case WordResult(:final result) when result == 'bonus':
        bonusWords++;
      case RacerProgress(:final id):
        progress[id] = e;
        if (id != me && e.fraction >= 0.75 && e.filled < e.total && _closeCalls.add(id)) {
          say('${nameOf(id)} is nearly done!', colorOf(id));
        }
      case VsRoundEnd(:final answers, :final next):
        standings = e;
        tally = {...e.tally};
        teamTally = e.teamTally ?? teamTally;
        for (final p in e.progress) {
          progress[p.id] = p;
        }
        mold?.showAnswers(answers);
        // No next round: this one decided the series.
        if (next == null) _holdFinalRound();
      case SeriesEnd():
        seriesEnd = e;
      case RoomSnapshot():
        _applySnapshot(e);
      default:
        break;
    }
  }

  void _applySnapshot(RoomSnapshot s) {
    lobby = s.lobby;
    // Back in the room: straight to wherever it is now, unless that's still
    // the round that decided the series, which carries on showing.
    final end = s.standings;
    if (s.round != null || end == null || end.next != null || end.round != standings?.round) _endFinalRound();
    if (s.round != null) {
      _beginRound(s.round!);
      for (final (slot, word) in s.mine) {
        _claim(slot, word);
      }
      for (final (slot, word) in s.mineAuto) {
        _claim(slot, word);
      }
      for (final p in s.progress) {
        progress[p.id] = p;
      }
    }
    if (s.standings != null) {
      final end = s.standings!;
      standings = end;
      tally = {...end.tally};
      teamTally = end.teamTally ?? teamTally;
      // Back during the standings: show that round's answers on my mold, or
      // drop a mold left over from an earlier round.
      if (end.round != null && round?.round != end.round) {
        mold = null;
      } else {
        mold?.showAnswers(end.answers);
      }
    }
    if (s.seriesEnd != null) seriesEnd = s.seriesEnd;
  }

  // ---- Actions ----

  /// Host only, in the lobby: best of [length] rounds.
  void config(int length) => client.config(series: length);

  /// Team Versus, host only, in the lobby or results: how the next series'
  /// rounds are won (`combined` or `first`).
  void setRule(String rule) => client.config(rule: rule);

  /// Team Versus, in the lobby or results: joins [team].
  void joinTeam(int team) => client.team(team);

  /// Team Versus, host only: moves [id] to [team].
  void moveToTeam(String id, int team) => client.team(team, id: id);

  /// Sends a word; the result arrives as a [WordResult] effect.
  void submit(String word) => client.submit(word);

  /// On from the round that decided the series to the podium, as soon as the
  /// series' results are in.
  void seeResults() {
    if (finalRoundUntil == null) return;
    _endFinalRound();
    notifyListeners();
  }

  @override
  void dispose() {
    _finalRoundDone?.cancel();
    super.dispose();
  }
}
