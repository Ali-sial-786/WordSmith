// Finished Versus series to look back at, for the round review's widget
// tests and screenshots.
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';

const reviewNames = ['Ada', 'sam', 'Kit', 'Bo', 'Wren'];

/// Up to five smiths in a Versus room's results; I'm u1 (Ada, copper).
/// Wren is offline.
RoomLobby reviewLobby({int players = 4, String phase = 'results'}) => RoomLobby.fromJson({
  'code': 'V5X7KQ',
  'mode': 'vs',
  'phase': phase,
  'hostId': 'u1',
  'heat': 3,
  'series': 5,
  'players': [
    for (var i = 1; i <= players; i++)
      {
        'id': 'u$i',
        'username': reviewNames[i - 1],
        'avatar': 'avatar_${(i * 3 % 16 + 1).toString().padLeft(2, '0')}',
        'level': 3 * i + 2,
        'color': i - 1,
        'ready': true,
        'connected': i != 5,
      },
  ],
});

VsSession reviewSession({int players = 4, String phase = 'results'}) => VsSession(
  client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'V5X7KQ', token: () async => 't'),
  me: 'u1',
)..lobby = reviewLobby(players: players, phase: phase);

/// The mold: STONE across the top, SEAT and EATS down its ends, TONES across
/// the fourth row, and NET down from its N. 16 letters, from the anvil STONEA.
const reviewSlots = [
  {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 5},
  {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 4},
  {'slot': 2, 'x': 4, 'y': 0, 'd': 'd', 'len': 4},
  {'slot': 3, 'x': 0, 'y': 3, 'd': 'a', 'len': 5},
  {'slot': 4, 'x': 2, 'y': 3, 'd': 'd', 'len': 3},
];

const reviewWords = ['STONE', 'SEAT', 'EATS', 'TONES', 'NET'];

/// Letter cells in [slots] of the review's mold.
int reviewFilled(List<int> slots) => {
  for (final i in slots)
    for (var k = 0; k < (reviewSlots[i]['len'] as int); k++)
      reviewSlots[i]['d'] == 'a'
          ? ((reviewSlots[i]['x'] as int) + k, reviewSlots[i]['y'] as int)
          : (reviewSlots[i]['x'] as int, (reviewSlots[i]['y'] as int) + k),
}.length;

/// One round of `SERIES_END.history` on the review's mold: letters follow the
/// molds. Without [words], as a server from before the review sends it.
Map<String, Object?> reviewRound(
  int round, {
  String? winner,
  String how = 'timeout',
  required Map<String, List<int>> molds,
  Map<String, List<String>> bins = const {},
  bool sudden = false,
  Map<String, Object>? melted,
  Map<String, int>? saved,
  bool words = true,
}) => {
  'round': round,
  'suddenDeath': sudden,
  'reason': how == 'finished' ? 'finished' : (melted != null ? 'melted' : 'timeout'),
  'winner': winner,
  'how': how,
  'cols': 5,
  'rows': 6,
  'slots': reviewSlots,
  'progress': [
    for (final e in molds.entries) {'id': e.key, 'filled': reviewFilled(e.value), 'total': 16},
  ],
  'molds': molds,
  'melted': ?melted,
  'saved': ?saved,
  if (words) ...{
    'letters': 'ATSNOE',
    'answers': [
      for (final (i, w) in reviewWords.indexed) {'slot': i, 'word': w},
    ],
    'bins': {for (final id in molds.keys) id: bins[id] ?? const <String>[]},
  },
};

SeriesEnd reviewSeries(List<Map<String, Object?>> history, {String? winner = 'u1', int players = 4}) {
  final wins = <String, int>{};
  for (final r in history) {
    if (r['winner'] case final String id) wins[id] = (wins[id] ?? 0) + 1;
  }
  final ids = [for (var i = 1; i <= players; i++) 'u$i']..sort((a, b) => (wins[b] ?? 0).compareTo(wins[a] ?? 0));
  return SeriesEnd.fromJson({
    'winner': winner,
    'early': false,
    'forfeit': false,
    'rounds': history.length,
    'podium': [
      for (final (i, id) in ids.indexed)
        {'id': id, 'username': reviewNames[int.parse(id.substring(1)) - 1], 'wins': wins[id] ?? 0, 'place': i + 1},
    ],
    'history': history,
    'xp': {},
  });
}

/// A classic best of 5 among four that I took in four: round 2 I found
/// nothing, round 3 sam won on time while I missed EATS and NET.
SeriesEnd classicSeries() => reviewSeries([
  reviewRound(
    1,
    winner: 'u1',
    how: 'finished',
    molds: {
      'u1': [0, 1, 2, 3, 4],
      'u2': [0, 3],
      'u3': [1],
      'u4': [0, 2],
    },
    bins: {
      'u1': ['ONE'],
      'u4': ['TOE', 'SAT'],
    },
  ),
  reviewRound(
    2,
    winner: 'u3',
    molds: {
      'u1': [],
      'u2': [4],
      'u3': [0, 1, 3],
      'u4': [2],
    },
    bins: {
      'u2': ['NOTE', 'TONE'],
      'u3': ['EAST'],
      'u4': ['OAT', 'TEN', 'SET', 'NEAT', 'ANTE', 'ETNA'],
    },
  ),
  reviewRound(
    3,
    winner: 'u2',
    molds: {
      'u1': [0, 1, 3],
      'u2': [0, 1, 2, 3],
      'u3': [0, 2],
      'u4': [1],
    },
    bins: {
      'u1': ['NOTE', 'TOE', 'EAST'],
      'u2': ['ONE'],
      'u4': ['SAT', 'OAT', 'NEAT', 'TONE', 'ANTE'],
    },
  ),
  reviewRound(
    4,
    winner: 'u1',
    how: 'finished',
    molds: {
      'u1': [0, 1, 2, 3, 4],
      'u2': [0, 2, 4],
      'u3': [0, 1],
      'u4': [1, 3],
    },
    bins: {
      'u1': ['TEN'],
      'u3': ['ONSET'],
    },
  ),
]);

/// A Survival best of 3 among four: in round 2 my heated NET melted, and Bo
/// survived the heat.
SeriesEnd survivalSeries() => reviewSeries([
  reviewRound(
    1,
    winner: 'u1',
    how: 'finished',
    molds: {
      'u1': [0, 1, 2, 3, 4],
      'u2': [0, 3],
      'u3': [1],
      'u4': [0, 2],
    },
    saved: {'u1': 5, 'u2': 2, 'u3': 1, 'u4': 2},
  ),
  reviewRound(
    2,
    winner: 'u4',
    how: 'survived',
    molds: {
      'u1': [0, 1],
      'u2': [0, 3],
      'u3': [2],
      'u4': [0, 1, 2],
    },
    bins: {
      'u1': ['TOE', 'ONE'],
      'u2': ['EAST'],
      'u4': ['NOTE'],
    },
    melted: {'id': 'u1', 'slot': 4},
    saved: {'u1': 2, 'u2': 1, 'u3': 0, 'u4': 3},
  ),
  reviewRound(
    3,
    winner: 'u1',
    how: 'survived',
    molds: {
      'u1': [0, 1, 3],
      'u2': [1],
      'u3': [],
      'u4': [2],
    },
    melted: {'id': 'u3', 'slot': 0},
    saved: {'u1': 3, 'u2': 1, 'u3': 0, 'u4': 1},
  ),
]);

/// A best of 10 among five that went to two sudden deaths between sam and
/// me; Wren left after round 6.
SeriesEnd longSeries() {
  const winners = ['u2', 'u1', 'u3', null, 'u4', 'u1', 'u2', 'u3', 'u1', 'u2'];
  return reviewSeries(players: 5, [
    for (final (i, winner) in winners.indexed)
      reviewRound(
        i + 1,
        winner: winner,
        how: winner == null ? 'none' : (i.isEven ? 'finished' : 'timeout'),
        molds: {
          for (var p = 1; p <= (i < 6 ? 5 : 4); p++)
            // A finisher fills the mold; on time, the most letters.
            'u$p': winner == null
                ? []
                : 'u$p' == winner
                ? (i.isEven ? [0, 1, 2, 3, 4] : [0, 1, 3])
                : [
                    for (var s = 0; s < 5; s++)
                      if ((s + p + i) % 3 == 0) s,
                  ],
        },
        bins: {
          'u1': [if (i.isOdd) 'TOE', if (i % 3 == 0) 'NOTE'],
          'u3': ['EAST'],
        },
      ),
    reviewRound(11, sudden: true, how: 'none', molds: {'u1': [], 'u2': []}),
    reviewRound(
      12,
      sudden: true,
      winner: 'u1',
      molds: {
        'u1': [0, 1, 2],
        'u2': [1, 3],
      },
      bins: {
        'u1': ['ONE', 'TEN'],
        'u2': ['OAT', 'SAT', 'NOTE'],
      },
    ),
  ]);
}
