import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/net/room_client.dart';

const _slots = [
  {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 3},
  {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 3},
  {'slot': 2, 'x': 2, 'y': 0, 'd': 'd', 'len': 3},
];

void main() {
  test("SERIES_END's history brings each round's words, anvil, Scrap Bins and words saved", () {
    final end = RoomEvent.parse({
      'op': 'SERIES_END',
      'winner': 'u1',
      'early': false,
      'forfeit': false,
      'rounds': 2,
      'podium': [],
      'xp': {},
      'history': [
        {
          'round': 1,
          'suddenDeath': false,
          'reason': 'melted',
          'winner': 'u1',
          'how': 'survived',
          'cols': 3,
          'rows': 3,
          'slots': _slots,
          'progress': [
            {'id': 'u1', 'filled': 3, 'total': 7},
            {'id': 'u2', 'filled': 0, 'total': 7},
          ],
          'molds': {
            'u1': [0],
            'u2': [],
          },
          'letters': 'TOACE',
          'answers': [
            {'slot': 0, 'word': 'CAT'},
            {'slot': 1, 'word': 'COT'},
            {'slot': 2, 'word': 'TOE'},
          ],
          'bins': {
            'u1': ['ACT', 'OAT'],
            'u2': [],
          },
          'melted': {'id': 'u2', 'slot': 1},
          'saved': {'u1': 1, 'u2': 0},
        },
        // From a server before the review: none of it.
        {
          'round': 2,
          'suddenDeath': false,
          'reason': 'timeout',
          'winner': null,
          'how': 'none',
          'cols': 3,
          'rows': 3,
          'slots': _slots,
          'progress': [],
          'molds': {'u1': [], 'u2': []},
        },
      ],
    }) as SeriesEnd;
    final first = end.history.first;
    expect(first.letters, 'TOACE');
    expect(first.answers, [(0, 'CAT'), (1, 'COT'), (2, 'TOE')]);
    expect(first.bins, {
      'u1': ['ACT', 'OAT'],
      'u2': <String>[],
    });
    expect(first.saved, {'u1': 1, 'u2': 0});
    expect(first.melted, (id: 'u2', slot: 1));

    final older = end.history.last;
    expect(older.letters, isEmpty);
    expect(older.answers, isEmpty);
    expect(older.bins, isEmpty);
    expect(older.saved, isEmpty);
    expect(older.melted, isNull);
  });
}
