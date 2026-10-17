import '../engine/puzzle.dart';
import '../net/room_client.dart';
import 'remote_mold.dart';
import 'room_session.dart';

export 'remote_mold.dart';
export 'room_session.dart';

/// One co-op room: the shared mold, the team's scores and the results.
class CoopSession extends RoomSession {
  CoopSession({required super.client, required super.me});

  RemoteMold? mold;
  RoundEnd? results;
  Map<String, int> scores = {};
  final Map<int, String> _pending = {};

  @override
  String? departedName(String id) {
    // Players who left mid-round are only named in the results.
    for (final p in results?.players ?? const <RoundPlayerResult>[]) {
      if (p.id == id && p.username.isNotEmpty) return p.username;
    }
    return null;
  }

  void _beginRound(RoundStart start) {
    round = start;
    results = null;
    scores = {};
    feed.clear();
    mold = RemoteMold(start, () => lobby!);
    syncClock(start.serverNow);
  }

  @override
  void handle(RoomEvent e) {
    switch (e) {
      case RoundStart():
        _beginRound(e);
      case WordClaimed(:final slot, :final word, :final by, :final points, :final auto):
        mold?.claim(slot, word, by);
        for (final (s, w) in auto) {
          mold?.claim(s, w, null);
        }
        scores = e.scores;
        say('${nameOf(by)} forged $word  +$points', colorOf(by));
      case BonusClaimed(:final word, :final by, :final points):
        scores = e.scores;
        say('${nameOf(by)} found bonus $word  +$points', colorOf(by));
      case Revealed(:final cells, :final auto, :final by):
        mold?.reveal(cells);
        for (final (s, w) in auto) {
          mold?.claim(s, w, null);
        }
        say('${nameOf(by)} used a ${e.kind == 'hammer' ? 'Hammer Strike' : e.kind == 'chisel' ? 'Chisel' : 'Spark Shower'}', colorOf(by));
      case RoundEnd(:final answers):
        results = e;
        mold?.showAnswers(answers);
      case RoomSnapshot():
        _applySnapshot(e);
      case WordResult(:final seq):
        _pending.remove(seq);
      default:
        break;
    }
  }

  void _applySnapshot(RoomSnapshot s) {
    lobby = s.lobby;
    if (s.round != null) {
      _beginRound(s.round!);
      for (final (slot, word, by) in s.claims) {
        mold!.claim(slot, word, by);
      }
      for (final (slot, word) in s.auto) {
        mold!.claim(slot, word, null);
      }
      mold!.reveal(s.revealed);
      scores = s.scores;
    }
    if (s.results != null) {
      results = s.results;
      mold?.showAnswers(s.results!.answers);
    }
  }

  /// Sends a word; the result arrives as a [WordResult] effect.
  void submit(String word) {
    final seq = client.submit(word);
    _pending[seq] = word;
  }

  void hint(String kind, {CellPos? cell}) => client.hint(kind, cell: cell);
}
