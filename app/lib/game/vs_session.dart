import '../net/room_client.dart';
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

  /// The last round's result, shown between rounds.
  VsRoundEnd? standings;
  SeriesEnd? seriesEnd;

  /// Bonus words found this round (they go to the Scrap Bin).
  int bonusWords = 0;

  /// Rivals already announced as nearly done this round.
  final Set<String> _closeCalls = {};

  /// Best of this many rounds.
  int get series => round?.series ?? lobby?.series ?? 3;

  /// Racing this round (in sudden death, the rest watch).
  bool get racing => round?.racers.contains(me) ?? false;

  /// The round has been decided; boards freeze until the next one.
  bool get roundOver => standings != null && round != null && phase != 'countdown';

  int get myFilled => mold?.filledLetters ?? 0;
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
    bonusWords = 0;
    _closeCalls.clear();
    feed.clear();
    mold = RemoteMold(start, () => lobby!, initials: false);
    final total = mold!.cells.length;
    progress = {for (final id in start.racers) id: RacerProgress(id, 0, total)};
    tally = {...start.tally};
    syncClock(start.serverNow);
  }

  void _claim(int slot, String word) => mold?.claim(slot, word, me);

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
      case VsRoundEnd(:final answers):
        standings = e;
        tally = {...e.tally};
        for (final p in e.progress) {
          progress[p.id] = p;
        }
        mold?.showAnswers(answers);
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

  /// Sends a word; the result arrives as a [WordResult] effect.
  void submit(String word) => client.submit(word);
}
