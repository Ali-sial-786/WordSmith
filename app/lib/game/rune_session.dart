import 'dart:async';

import '../net/room_client.dart';
import 'room_session.dart';

export 'room_session.dart';

/// One Rune Rush room (shared/rune-rush.md): everyone on the same grid of
/// letter dice, finding words before the timer runs out. Rivals' word counts
/// show as they go, never their words; points are worked out when the round
/// ends, a word only one smith (or team) found scoring double.
class RuneSession extends RoomSession {
  RuneSession({required super.client, required super.me});

  /// The round on now (or just over).
  RuneRoundStart? grid;

  /// My words this round, in the order found; in pooled Team Rune Rush, my
  /// team's.
  final List<RuneWord> mine = [];

  /// How many words each racer has found this round.
  Map<String, int> tally = {};

  /// Points over the game: before this round while it's on, after it once
  /// it's over.
  Map<String, int> totals = {};

  /// Team Rune Rush: each team's points, as for [totals].
  List<int> teamTotals = const [0, 0];

  /// The last round's end, shown between rounds.
  RuneRoundEnd? standings;

  /// A round that ended while I was here, its words still to be counted on
  /// screen (one that ended before I came back isn't counted again).
  int? countRound;
  SeriesEnd? seriesEnd;

  /// How long the round that decided the game stays up before the podium.
  /// "See the results" moves on sooner.
  static const finalRoundHold = Duration(seconds: 16);

  /// Until when the round that decided the game shows by itself (this
  /// phone's clock); null once that's over or the player moved on.
  DateTime? finalRoundUntil;
  Timer? _finalRoundDone;

  @override
  int? get roundStartsAt => grid?.startsAt;
  @override
  int? get roundEndsAt => grid?.endsAt;

  /// The next game's settings, or during one, its own.
  RuneSettings get settings => lobby?.rune ?? const RuneSettings();

  /// Team Rune Rush.
  bool get isTeam => grid?.isTeam ?? lobby?.mode == 'runeteam';

  /// Team Rune Rush where a team shares one list of words.
  bool get pooled => isTeam && (grid?.pooled ?? settings.pooled);

  /// The game's rounds (a tiebreaker comes after).
  int get rounds => grid?.rounds ?? settings.rounds;

  /// The shortest word, in letters.
  int get minLength => grid?.min ?? settings.min;

  /// I race this round (in a tiebreaker, only the tied leaders do).
  bool get racing => grid?.players.contains(me) ?? false;

  /// The round has ended; the grid freezes until the next.
  bool get roundOver => standings != null && grid != null && standings!.round == grid!.round && phase != 'countdown';

  /// The standings are of the round that decided the game.
  bool get finalRound => standings != null && standings!.next == null;

  /// The round that decided the game is still showing: the podium waits
  /// for the hold (or "See the results"), and for the results to arrive.
  bool get showingFinalRound => finalRound && (finalRoundUntil != null || seriesEnd == null);

  Duration get finalRoundLeft {
    final left = finalRoundUntil?.difference(DateTime.now()) ?? Duration.zero;
    return left.isNegative ? Duration.zero : left;
  }

  @override
  int? teamOf(String id) => grid?.teams[id] ?? lobby?.player(id)?.team;

  /// [word] is on my list (or my team's) already.
  bool has(String word) => mine.any((w) => w.word == word);

  /// What my words come to so far, before any doubling at the round's end.
  int get myPoints => mine.fold(0, (sum, w) => sum + w.points);

  /// [id]'s points over the game, as [totals].
  int totalOf(String id) => totals[id] ?? 0;

  /// Racers by points over the game, then words this round; then the rest of the room.
  List<String> get standingsOrder {
    final ids = <String>{...totals.keys, ...?grid?.players, ...?lobby?.players.map((p) => p.id)}.toList();
    ids.sort((a, b) {
      final byPoints = totalOf(b).compareTo(totalOf(a));
      return byPoints != 0 ? byPoints : (tally[b] ?? 0).compareTo(tally[a] ?? 0);
    });
    return ids;
  }

  @override
  String? departedName(String id) {
    for (final p in seriesEnd?.podium ?? const <PodiumPlace>[]) {
      if (p.id == id && p.username.isNotEmpty) return p.username;
    }
    return null;
  }

  void _begin(RuneRoundStart start) {
    grid = start;
    standings = null;
    countRound = null;
    seriesEnd = null;
    _endFinalRound();
    mine.clear();
    feed.clear();
    tally = {for (final id in start.players) id: 0};
    totals = {...start.totals};
    teamTotals = start.teamTotals ?? const [0, 0];
    syncClock(start.serverNow);
  }

  void _ended(RuneRoundEnd end) {
    standings = end;
    if (end.totals.isNotEmpty) totals = {...end.totals};
    teamTotals = end.teamTotals ?? teamTotals;
    for (final e in end.found.entries) {
      tally[e.key] = e.value.length;
    }
  }

  void _holdFinalRound() {
    finalRoundUntil = DateTime.now().add(finalRoundHold);
    _finalRoundDone?.cancel();
    _finalRoundDone = Timer(finalRoundHold, seeResults);
  }

  void _endFinalRound() {
    finalRoundUntil = null;
    _finalRoundDone?.cancel();
  }

  @override
  void handle(RoomEvent e) {
    switch (e) {
      case RuneRoundStart():
        _begin(e);
      case WordResult(:final result, :final word, :final points) when result == 'found':
        if (!has(word)) mine.add(RuneWord(word, me, points));
      case RuneWordFound(:final word):
        if (!has(word.word)) {
          mine.add(word);
          say('${nameOf(word.by)} found ${word.word}', colorOf(word.by));
        }
      case RuneTally(:final id, :final words):
        tally[id] = words;
      case RuneRoundEnd(:final next):
        _ended(e);
        countRound = e.round;
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
    final end = s.runeStandings;
    if (s.runeRound != null || end == null || end.next != null || end.round != standings?.round) _endFinalRound();
    if (s.runeRound case final round?) {
      _begin(round);
      mine.addAll(s.runeMine);
      tally = {...tally, ...s.runeTally};
    }
    if (end != null) {
      // Back during the standings: drop a grid left over from an earlier round.
      if (grid != null && grid!.round != end.round) grid = null;
      _ended(end);
    }
    if (s.seriesEnd != null) seriesEnd = s.seriesEnd;
  }

  // ---- Actions ----

  /// Host only, in the lobby or results: the next game's settings.
  void setRune({int? size, int? seconds, int? min, int? rounds, String? teamScoring}) => client.config(
    rune: {'size': ?size, 'seconds': ?seconds, 'min': ?min, 'rounds': ?rounds, 'teamScoring': ?teamScoring},
  );

  /// Sends a word traced on the grid; the result arrives as a [WordResult] effect.
  void submit(String word) => client.submit(word);

  /// On from the round that decided the game to the podium.
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
