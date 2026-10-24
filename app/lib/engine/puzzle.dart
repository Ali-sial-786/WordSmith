/// Puzzle model. The JSON shape is defined in `shared/puzzle-format.md`.
library;

enum Direction { across, down }

/// A grid position: column [x], row [y].
typedef CellPos = ({int x, int y});

/// One answer slot in the mold.
class Slot {
  Slot({required this.index, required this.word, required this.x, required this.y, required this.direction});

  final int index;
  final String word;
  final int x;
  final int y;
  final Direction direction;

  int get length => word.length;

  late final List<CellPos> cells = [
    for (var i = 0; i < word.length; i++) direction == Direction.across ? (x: x + i, y: y) : (x: x, y: y + i),
  ];
}

class Puzzle {
  Puzzle({
    required this.id,
    required this.letters,
    required this.heat,
    required this.cols,
    required this.rows,
    required this.slots,
    required this.bonus,
    this.size,
  }) {
    final letterAt = <CellPos, String>{};
    final slotsAt = <CellPos, List<Slot>>{};
    for (final slot in slots) {
      for (var i = 0; i < slot.length; i++) {
        final cell = slot.cells[i];
        final letter = slot.word[i];
        final existing = letterAt[cell];
        if (existing != null && existing != letter) {
          throw FormatException('Puzzle $id: crossing letters disagree at $cell');
        }
        letterAt[cell] = letter;
        (slotsAt[cell] ??= []).add(slot);
      }
    }
    this.letterAt = Map.unmodifiable(letterAt);
    this.slotsAt = Map.unmodifiable(slotsAt);
    cells = List.unmodifiable(
      letterAt.keys.toList()..sort((a, b) => a.y != b.y ? a.y.compareTo(b.y) : a.x.compareTo(b.x)),
    );
    slotByWord = {for (final s in slots) s.word: s};
  }

  factory Puzzle.fromJson(Map<String, dynamic> json) {
    final words = (json['words'] as List).cast<Map<String, dynamic>>();
    return Puzzle(
      id: json['id'] as String,
      letters: json['letters'] as String,
      heat: json['heat'] as int,
      cols: json['cols'] as int,
      rows: json['rows'] as int,
      size: json['size'] as int?,
      slots: [
        for (var i = 0; i < words.length; i++)
          Slot(
            index: i,
            word: words[i]['w'] as String,
            x: words[i]['x'] as int,
            y: words[i]['y'] as int,
            direction: words[i]['d'] == 'a' ? Direction.across : Direction.down,
          ),
      ],
      bonus: Set.unmodifiable((json['bonus'] as List).cast<String>()),
    );
  }

  final String id;

  /// Anvil letters in their default order.
  final String letters;
  final int heat;
  final int cols;
  final int rows;
  final List<Slot> slots;
  final Set<String> bonus;

  /// Multiplayer bank only: players this puzzle is sized for.
  final int? size;

  /// Solution letter for every cell that belongs to a word.
  late final Map<CellPos, String> letterAt;

  /// The slots passing through each cell (one, or two at a crossing).
  late final Map<CellPos, List<Slot>> slotsAt;

  /// Every letter cell, sorted by row then column (the order pickups use).
  late final List<CellPos> cells;

  late final Map<String, Slot> slotByWord;

  int get letterCount => cells.length;

  /// The anvil's letters and every slot, as text: two puzzles with the same
  /// fingerprint play the same. A save records it, so a puzzle that changed
  /// under the same id (a new campaign) isn't restored onto the wrong grid.
  late final String fingerprint = [
    (letters.split('')..sort()).join(),
    for (final s in slots) '${s.word}@${s.x},${s.y}${s.direction == Direction.across ? 'a' : 'd'}',
  ].join(' ');
}
