import '../data/history.dart';
import '../net/room_client.dart';

/// One word from the puzzle history: the word, when its game ended, and
/// which game it was (its history title).
class WordEntry {
  const WordEntry({required this.word, required this.at, required this.from, required this.kind});

  final String word;

  /// When the game it came from finished, epoch ms.
  final int at;
  final String from;
  final PlayKind kind;
}

/// Every word I found in the games the history keeps, newest first: the
/// grid words I forged ([WordHistory.game]) and the bonus words that went
/// to my Scrap Bin ([WordHistory.scrap]). Built from the history, so it
/// reaches back as far as that does (`historyLimit` games).
class WordHistory {
  const WordHistory({required this.game, required this.scrap});

  factory WordHistory.from(List<PlayRecord> records) {
    final game = <WordEntry>[];
    final scrap = <WordEntry>[];
    for (final r in [...records]..sort((a, b) => b.at.compareTo(a.at))) {
      WordEntry entry(String word) => WordEntry(word: word, at: r.at, from: r.title, kind: r.kind);
      switch (r.kind) {
        case PlayKind.campaign || PlayKind.replay || PlayKind.daily || PlayKind.crucible:
          // A run's later puzzles are its more recent ones.
          for (final b in r.boards.reversed) {
            game.addAll([
              for (final s in b.puzzle.slots)
                if (b.found.contains(s.index)) entry(s.word),
            ]);
            // The Crucible has no Scrap Bin.
            if (r.kind != PlayKind.crucible) scrap.addAll(b.bonus.map(entry));
          }
        case PlayKind.coop:
          for (final b in r.boards) {
            game.addAll([
              for (final s in b.puzzle.slots)
                if (b.owners[s.index] == r.me) entry(s.word),
            ]);
          }
          // Only the bonus words I found myself (records from before 0.8 don't say).
          scrap.addAll(((r.result['scrap'] as List?) ?? const []).cast<String>().map(entry));
        case PlayKind.vs:
          final series = _series(r);
          final me = r.me;
          if (series == null || me == null) break;
          for (final round in series.history.reversed) {
            final words = {for (final (slot, word) in round.answers) slot: word};
            game.addAll([for (final slot in round.molds[me] ?? const <int>[]) ?words[slot]].map(entry));
            scrap.addAll((round.bins[me] ?? const []).map(entry));
          }
      }
    }
    return WordHistory(game: game, scrap: scrap);
  }

  final List<WordEntry> game;
  final List<WordEntry> scrap;

  static SeriesEnd? _series(PlayRecord r) {
    final raw = r.series;
    if (raw == null) return null;
    try {
      return SeriesEnd.fromJson(raw);
    } on Object {
      return null;
    }
  }
}
