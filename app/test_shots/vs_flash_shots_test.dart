// Renders the Versus round card (as it comes in, at its peak and settled) and
// the standings after the round that decided the series, with the real fonts.
// Not part of the suite: flutter test test_shots/vs_flash_shots_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/vs/vs_standings_view.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_grid.dart';
import 'package:wordsmith/ui/theme/theme.dart';
import 'package:wordsmith/ui/widgets/avatar_badge.dart';
import 'package:wordsmith/ui/widgets/forge_background.dart';
import 'package:wordsmith/ui/widgets/forge_frame.dart';
import 'package:wordsmith/ui/widgets/game_icon.dart';

const _names = ['Ada', 'sam', 'Kit', 'Bo', 'Wren'];

RoomLobby _lobby(String phase, int players) => RoomLobby.fromJson({
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
        'username': _names[i - 1],
        'avatar': 'avatar_${(i * 3 % 16 + 1).toString().padLeft(2, '0')}',
        'level': 3 * i + 2,
        'color': i - 1,
        'ready': true,
        'connected': true,
      },
  ],
});

/// The shots' 5×5 mold: STONE, SEAT, EATEN, TON, ONE (16 letters).
final _slots = [
  {'slot': 0, 'x': 0, 'y': 0, 'd': 'a', 'len': 5},
  {'slot': 1, 'x': 0, 'y': 0, 'd': 'd', 'len': 4},
  {'slot': 2, 'x': 4, 'y': 0, 'd': 'd', 'len': 5},
  {'slot': 3, 'x': 0, 'y': 3, 'd': 'a', 'len': 3},
  {'slot': 4, 'x': 2, 'y': 2, 'd': 'a', 'len': 3},
];

const _words = ['STONE', 'SEAT', 'EATEN', 'TON', 'ONE'];

int _filledOf(List<int> slots) => {
  for (final i in slots)
    for (var k = 0; k < (_slots[i]['len'] as int); k++)
      _slots[i]['d'] == 'a'
          ? ((_slots[i]['x'] as int) + k, _slots[i]['y'] as int)
          : (_slots[i]['x'] as int, (_slots[i]['y'] as int) + k),
}.length;

/// A room just after a round: [molds] are everyone's complete slots, [tally]
/// the wins after it. [deciding] rounds decide the series, which [series]
/// (a winner id, or '' for none yet) has come in for.
VsSession _clash({
  int players = 4,
  int round = 3,
  bool sudden = false,
  required String? winner,
  required String how,
  required Map<String, List<int>> molds,
  required Map<String, int> tally,
  bool deciding = false,
  String? series,
  Map<String, Object>? melted,
}) {
  final racers = molds.keys.toList();
  final start = RoundStart.fromJson({
    'round': round,
    'heat': 3,
    'startsAt': 0,
    'endsAt': DateTime.now().millisecondsSinceEpoch,
    'serverNow': DateTime.now().millisecondsSinceEpoch,
    'letters': 'STONEA',
    'cols': 5,
    'rows': 5,
    'slots': _slots,
    'pickups': [],
    'series': 5,
    'regular': sudden ? null : round,
    'suddenDeath': sudden,
    'players': racers,
    'tally': {for (final e in tally.entries) e.key: e.value - (e.key == winner ? 1 : 0)},
    'variant': melted == null ? 'classic' : 'survival',
  });
  final end = VsRoundEnd.fromJson({
    'round': round,
    'reason': melted != null ? 'melted' : (how == 'finished' ? 'finished' : 'timeout'),
    'winner': winner,
    'how': how,
    'progress': [
      for (final e in molds.entries) {'id': e.key, 'filled': _filledOf(e.value), 'total': 16},
    ],
    'molds': molds,
    'tally': tally,
    'answers': [
      for (final (i, w) in _words.indexed) {'slot': i, 'word': w},
    ],
    'next': deciding
        ? null
        : {
            'round': round + 1,
            'suddenDeath': false,
            'players': [for (var i = 1; i <= players; i++) 'u$i'],
          },
    'standingsEndsAt': deciding ? null : DateTime.now().millisecondsSinceEpoch + 6400,
    'melted': ?melted,
  });
  final lobby = _lobby(deciding ? 'results' : 'standings', players);
  final s = VsSession(
    client: RoomClient(baseUrl: 'http://127.0.0.1:9', code: 'V5X7KQ', token: () async => 't'),
    me: 'u1',
  )..lobby = lobby;
  s
    ..round = start
    ..mold = RemoteMold(start, () => lobby)
    ..standings = end
    ..tally = end.tally;
  for (final slot in molds['u1'] ?? const <int>[]) {
    s.mold!.claim(slot, _words[slot], 'u1');
  }
  s.mold!.showAnswers(end.answers);
  if (deciding) {
    s.finalRoundUntil = DateTime.now().add(const Duration(milliseconds: 5600));
    if (series != null) {
      s.seriesEnd = SeriesEnd.fromJson({
        'winner': series.isEmpty ? null : series,
        'early': true,
        'forfeit': false,
        'rounds': round,
        'podium': [],
        'xp': {},
      });
    }
  }
  return s;
}

Future<void> _font(String family, Future<ByteData> data) async {
  final loader = FontLoader(family)..addFont(data);
  await loader.load();
}

Widget _app(Store store, Widget child) => ProviderScope(
  overrides: [storeProvider.overrideWithValue(store)],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: Scaffold(
      body: ForgeBackground(
        image: 'assets/images/bg_hall.webp',
        dim: 0.6,
        fire: 0.0,
        child: SafeArea(child: child),
      ),
    ),
  ),
);

/// Everything the card draws, loaded before its clock starts.
class _WarmUp extends StatelessWidget {
  const _WarmUp();

  @override
  Widget build(BuildContext context) => Wrap(
    children: [
      for (final kind in ForgeFrameKind.values) SizedBox(width: 120, height: 70, child: ForgeFrame(kind: kind)),
      for (final icon in ['crown', 'anvil', 'trophy']) GameIcon(icon),
      for (var i = 1; i <= 16; i++) AvatarBadge(avatar: 'avatar_${i.toString().padLeft(2, '0')}', size: 20),
      Image.asset('assets/images/hammer_strike.png', width: 40),
    ],
  );
}

/// Shoots [view] at each of [frames] (a name and the ms since the card
/// showed), stepping the clock a frame at a time so sparks fly as they would.
Future<void> _frames(
  WidgetTester tester,
  String name,
  Widget Function() view,
  List<(String, int)> frames, {
  Size size = const Size(412, 892),
  bool calm = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': calm, 'haptics': false}),
  });
  final store = await Store.open();
  await tester.binding.setSurfaceSize(size);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app(store, const _WarmUp()));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await tester.pumpWidget(_app(store, view()));
  // The card's clock starts on its first frame.
  await tester.pump();
  await tester.pump();
  var at = 0;
  for (final (frame, ms) in frames) {
    while (at < ms) {
      final step = min(16, ms - at);
      await tester.pump(Duration(milliseconds: step));
      at += step;
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/${name}_$frame.png'));
  }
  await tester.pumpWidget(const SizedBox());
}

Widget _standings(VsSession s) => VsStandingsView(session: s, cues: MoldCues(), onLeave: () {});

void main() {
  setUpAll(() async {
    await _font('Cinzel', rootBundle.load('assets/fonts/Cinzel-Variable.ttf'));
    await _font('RobotoSlab', rootBundle.load('assets/fonts/RobotoSlab-Variable.ttf'));
    await _font('NunitoSans', rootBundle.load('assets/fonts/NunitoSans-Variable.ttf'));
    final icons = File('/opt/sdk/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
        .readAsBytesSync();
    await _font('MaterialIcons', Future.value(ByteData.view(icons.buffer)));
  });

  // I fill the mold first: the hammer comes down, sparks, then the banner.
  testWidgets('vs flash win', (tester) async {
    await _frames(
      tester,
      'vs_flash_win',
      () => _standings(
        _clash(
          winner: 'u1',
          how: 'finished',
          molds: {
            'u1': [0, 1, 2, 3, 4],
            'u2': [0, 1, 3],
            'u3': [3],
            'u4': [0, 2, 4],
          },
          tally: {'u1': 2, 'u2': 1, 'u3': 0, 'u4': 0},
        ),
      ),
      [
        ('1_entering', 200),
        ('2_strike', 400),
        ('3_sparks', 520),
        ('4_peak', 1500),
        ('5_settling', 4000),
        ('6_settled', 4800),
      ],
    );
  });

  testWidgets('vs flash rival', (tester) async {
    await _frames(
      tester,
      'vs_flash_rival',
      () => _standings(
        _clash(
          winner: 'u2',
          how: 'timeout',
          molds: {
            'u1': [0, 3],
            'u2': [0, 1, 2],
            'u3': [3],
            'u4': [1],
          },
          tally: {'u1': 1, 'u2': 2, 'u3': 0, 'u4': 0},
        ),
      ),
      [('1_landing', 200), ('2_peak', 1500), ('3_settled', 4800)],
    );
  });

  testWidgets('vs flash none', (tester) async {
    await _frames(
      tester,
      'vs_flash_none',
      () => _standings(
        _clash(
          winner: null,
          how: 'none',
          molds: {'u1': [], 'u2': [], 'u3': [], 'u4': []},
          tally: {'u1': 1, 'u2': 1, 'u3': 0, 'u4': 0},
        ),
      ),
      [('1_peak', 1500), ('2_settled', 4800)],
    );
  });

  // Survival: Bo's heated word melts, and I've the most letters left.
  testWidgets('vs flash melt', (tester) async {
    await _frames(
      tester,
      'vs_flash_melt',
      () => _standings(
        _clash(
          players: 5,
          winner: 'u1',
          how: 'survived',
          molds: {
            'u1': [0, 1, 3],
            'u2': [0, 1],
            'u3': [3],
            'u4': [0, 2],
            'u5': [],
          },
          tally: {'u1': 2, 'u2': 1, 'u3': 0, 'u4': 1, 'u5': 0},
          melted: {'id': 'u4', 'slot': 4},
        ),
      ),
      [('1_peak', 1500), ('2_settled', 4800)],
      size: const Size(360, 740),
    );
  });

  // Sudden death between sam and me, and sam takes it and the series.
  testWidgets('vs flash sudden death', (tester) async {
    await _frames(
      tester,
      'vs_flash_sudden',
      () => _standings(
        _clash(
          round: 6,
          sudden: true,
          winner: 'u2',
          how: 'finished',
          molds: {
            'u1': [0, 1, 3],
            'u2': [0, 1, 2, 3, 4],
          },
          tally: {'u1': 2, 'u2': 3, 'u3': 1, 'u4': 0},
          deciding: true,
          series: 'u2',
        ),
      ),
      [('1_peak', 2200), ('2_settled', 4800)],
    );
  });

  // I clinch the series in round 4: the round, then the series slammed home.
  testWidgets('vs flash series', (tester) async {
    await _frames(
      tester,
      'vs_flash_series',
      () => _standings(
        _clash(
          round: 4,
          winner: 'u1',
          how: 'finished',
          molds: {
            'u1': [0, 1, 2, 3, 4],
            'u2': [0, 2, 4],
            'u3': [0, 1],
            'u4': [1, 3],
          },
          tally: {'u1': 3, 'u2': 1, 'u3': 0, 'u4': 0},
          deciding: true,
          series: 'u1',
        ),
      ),
      [('1_round', 1100), ('2_ribbon', 1420), ('3_ribbon_sparks', 1600), ('4_peak', 2600), ('5_settled', 4500)],
    );
  });

  // After the card: everyone's molds, and the way to the podium.
  testWidgets('vs final standings', (tester) async {
    await _frames(
      tester,
      'vs_final_standings',
      () => _standings(
        _clash(
          round: 4,
          winner: 'u1',
          how: 'finished',
          molds: {
            'u1': [0, 1, 2, 3, 4],
            'u2': [0, 2, 4],
            'u3': [0, 1],
            'u4': [1, 3],
          },
          tally: {'u1': 3, 'u2': 1, 'u3': 0, 'u4': 0},
          deciding: true,
          series: 'u1',
        ),
      ),
      [('settled', 5800)],
    );
  });

  // Reduced motion: no hammer, sparks or flying; the card shows, then the banner.
  testWidgets('vs flash calm', (tester) async {
    await _frames(
      tester,
      'vs_flash_calm',
      () => _standings(
        _clash(
          winner: 'u1',
          how: 'timeout',
          molds: {
            'u1': [0, 1, 2],
            'u2': [0, 3],
            'u3': [3],
            'u4': [1],
          },
          tally: {'u1': 2, 'u2': 1, 'u3': 0, 'u4': 0},
        ),
      ),
      [('1_card', 300), ('2_settled', 4000)],
      calm: true,
    );
  });
}
