import '../engine/board.dart';
import '../engine/puzzle.dart';

/// Where a played puzzle came from.
enum PlayKind {
  campaign,
  replay,
  daily,
  crucible,
  coop,
  vs;

  static PlayKind byName(String? name) => values.firstWhere((k) => k.name == name, orElse: () => campaign);
}

/// One finished puzzle as the history keeps it: the whole puzzle, so it reads
/// back the same even after the campaign changes, and what became of each word.
class PlayedBoard {
  PlayedBoard({
    required this.puzzle,
    required this.found,
    this.auto = const {},
    this.revealed = const [],
    this.bonus = const [],
    this.owners = const {},
    this.melted,
  });

  /// A solo board as it ended. [melted] is the Crucible's heated slot that melted.
  factory PlayedBoard.fromBoard(Board board, {int? melted}) => PlayedBoard(
    puzzle: board.puzzle,
    found: board.foundSlots,
    auto: board.autoSlots,
    revealed: board.revealed.toList(),
    bonus: board.bonusFound.toList()..sort(),
    melted: melted,
  );

  factory PlayedBoard.fromJson(Map<String, dynamic> j) {
    final words = (j['words'] as List).cast<Map<String, dynamic>>();
    return PlayedBoard(
      puzzle: Puzzle(
        id: j['id'] as String? ?? '',
        letters: j['letters'] as String? ?? '',
        heat: (j['heat'] as num?)?.toInt() ?? 1,
        cols: (j['cols'] as num).toInt(),
        rows: (j['rows'] as num).toInt(),
        slots: [
          for (var i = 0; i < words.length; i++)
            Slot(
              index: i,
              word: words[i]['w'] as String,
              x: (words[i]['x'] as num).toInt(),
              y: (words[i]['y'] as num).toInt(),
              direction: words[i]['d'] == 'a' ? Direction.across : Direction.down,
            ),
        ],
        bonus: const {},
      ),
      found: {...((j['found'] as List?) ?? const []).cast<int>()},
      auto: {...((j['auto'] as List?) ?? const []).cast<int>()},
      revealed: [for (final c in ((j['revealed'] as List?) ?? const []).cast<List>()) (x: c[0] as int, y: c[1] as int)],
      bonus: ((j['bonus'] as List?) ?? const []).cast<String>(),
      owners: {
        for (final e in ((j['owners'] as Map?) ?? const {}).entries) int.parse(e.key as String): e.value as String,
      },
      melted: (j['melted'] as num?)?.toInt(),
    );
  }

  /// Its words in slot order (slot index = position); no bonus list.
  final Puzzle puzzle;

  /// Slots forged: by me in solo play, by anyone on the team in co-op.
  final Set<int> found;

  /// Slots that filled in by themselves (every letter forged or hinted).
  final Set<int> auto;

  /// Letters hints showed.
  final List<CellPos> revealed;

  /// Bonus words found.
  final List<String> bonus;

  /// Co-op: who forged each slot.
  final Map<int, String> owners;

  /// The Crucible: the heated slot that melted, ending the run.
  final int? melted;

  bool isDone(int slot) => found.contains(slot) || auto.contains(slot);

  /// Words nobody forged.
  List<Slot> get missed => [
    for (final s in puzzle.slots)
      if (!isDone(s.index)) s,
  ];

  bool get complete => missed.isEmpty;

  Map<String, Object?> toJson() => {
    'id': puzzle.id,
    'letters': puzzle.letters,
    'heat': puzzle.heat,
    'cols': puzzle.cols,
    'rows': puzzle.rows,
    'words': [
      for (final s in puzzle.slots) {'w': s.word, 'x': s.x, 'y': s.y, 'd': s.direction == Direction.across ? 'a' : 'd'},
    ],
    'found': found.toList()..sort(),
    if (auto.isNotEmpty) 'auto': auto.toList()..sort(),
    if (revealed.isNotEmpty)
      'revealed': [
        for (final c in revealed) [c.x, c.y],
      ],
    if (bonus.isNotEmpty) 'bonus': bonus,
    if (owners.isNotEmpty) 'owners': {for (final e in owners.entries) '${e.key}': e.value},
    'melted': ?melted,
  };
}

/// Someone who played a co-op round or Versus series, as they were then.
class PlayedPlayer {
  const PlayedPlayer({required this.id, required this.username, required this.color, this.avatar = 'avatar_01'});

  factory PlayedPlayer.fromJson(Map<String, dynamic> j) => PlayedPlayer(
    id: j['id'] as String,
    username: j['username'] as String? ?? '?',
    color: (j['color'] as num?)?.toInt() ?? 0,
    avatar: j['avatar'] as String? ?? 'avatar_01',
  );

  final String id;
  final String username;

  /// Their room colour (Palette.player).
  final int color;
  final String avatar;

  Map<String, Object?> toJson() => {'id': id, 'username': username, 'color': color, 'avatar': avatar};
}

/// One entry in the puzzle history: a solo puzzle, a Crucible run, a co-op
/// round or a Versus series, kept on this phone (Store.loadHistory).
class PlayRecord {
  PlayRecord({
    required this.id,
    required this.kind,
    required this.at,
    required this.title,
    required this.subtitle,
    this.look = 'tin',
    this.boards = const [],
    this.players = const [],
    this.me,
    this.result = const {},
    this.series,
  });

  factory PlayRecord.fromJson(Map<String, dynamic> j) => PlayRecord(
    id: j['id'] as String,
    kind: PlayKind.byName(j['kind'] as String?),
    at: (j['at'] as num).toInt(),
    title: j['title'] as String? ?? '',
    subtitle: j['subtitle'] as String? ?? '',
    look: j['look'] as String? ?? 'tin',
    boards: [
      for (final b in ((j['boards'] as List?) ?? const []).cast<Map<String, dynamic>>()) PlayedBoard.fromJson(b),
    ],
    players: [
      for (final p in ((j['players'] as List?) ?? const []).cast<Map<String, dynamic>>()) PlayedPlayer.fromJson(p),
    ],
    me: j['me'] as String?,
    result: ((j['result'] as Map?) ?? const {}).cast<String, Object?>(),
    series: (j['series'] as Map?)?.cast<String, dynamic>(),
  );

  /// Unique; a record saved again under the same id replaces the old one.
  final String id;
  final PlayKind kind;

  /// When it finished, epoch ms.
  final int at;
  final String title;
  final String subtitle;

  /// The chapter whose metal the boards are drawn in.
  final String look;

  /// The puzzles played: one, or a Crucible run's in order. Versus keeps its
  /// rounds in [series] instead.
  final List<PlayedBoard> boards;

  /// Co-op and Versus: who played, as they were then.
  final List<PlayedPlayer> players;

  /// Co-op and Versus: my user id then.
  final String? me;

  /// What the mode reports: `stars`, `teamScore`, `points`, `completed`,
  /// `melted`, `cleared`, `saved`, `winner`, `wins`, `xp`, `elapsedMs`,
  /// `hints`, `code`, `rounds`, `mvp`…
  final Map<String, Object?> result;

  /// Versus: the SERIES_END message as it came, for the round-by-round look back.
  final Map<String, dynamic>? series;

  T? get<T>(String key) => result[key] is T ? result[key] as T : null;

  PlayedPlayer? player(String? id) {
    for (final p in players) {
      if (p.id == id) return p;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'at': at,
    'title': title,
    'subtitle': subtitle,
    'look': look,
    if (boards.isNotEmpty) 'boards': [for (final b in boards) b.toJson()],
    if (players.isNotEmpty) 'players': [for (final p in players) p.toJson()],
    'me': ?me,
    if (result.isNotEmpty) 'result': result,
    'series': ?series,
  };
}

/// The most entries kept; older ones drop off.
const historyLimit = 150;

/// [records] with [record] in front, replacing any entry with its id, and
/// cut to [historyLimit].
List<PlayRecord> withRecord(List<PlayRecord> records, PlayRecord record) {
  final next = [record, ...records.where((r) => r.id != record.id)]..sort((a, b) => b.at.compareTo(a.at));
  return next.length > historyLimit ? next.sublist(0, historyLimit) : next;
}
