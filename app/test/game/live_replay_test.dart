import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/game/coop_session.dart';
import 'package:wordsmith/game/vs_session.dart';
import 'package:wordsmith/net/room_client.dart';
import 'package:wordsmith/ui/mold/mold_model.dart';

/// Messages recorded from the live server (scratch scripts playing real
/// rooms with throwaway accounts), replayed into the app's sessions. This
/// catches any gap between what the server really sends and what the app
/// parses.
({String me, List<Map<String, dynamic>> events}) _load(String name) {
  final j = jsonDecode(File('test/fixtures/live/$name').readAsStringSync()) as Map<String, dynamic>;
  return (me: j['me'] as String, events: (j['events'] as List).cast<Map<String, dynamic>>());
}

/// A local room that plays back a recording to whoever connects.
Future<HttpServer> _replay(List<Map<String, dynamic>> events) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final ws = await WebSocketTransformer.upgrade(req, protocolSelector: (offered) => offered.first);
    for (final e in events) {
      ws.add(jsonEncode(e));
    }
  });
  return server;
}

Future<void> _until(bool Function() ok) async {
  for (var i = 0; i < 300 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ok(), isTrue);
}

void main() {
  test('every live message parses', () {
    for (final name in ['vs_series_guest.json', 'coop_round_host.json']) {
      for (final e in _load(name).events) {
        expect(RoomEvent.parse(e), isNotNull, reason: '$name: ${e['op']}');
      }
    }
  });

  test('a live Versus series replays into the app: rounds, progress, standings, podium', () async {
    final rec = _load('vs_series_guest.json');
    final server = await _replay(rec.events);
    addTearDown(() => server.close(force: true));
    final s = VsSession(
      client: RoomClient(baseUrl: 'http://127.0.0.1:${server.port}', code: 'LIVE', token: () async => 't'),
      me: rec.me,
    );
    addTearDown(s.dispose);
    final seen = <Type>{};
    s.effects.listen((e) => seen.add(e.runtimeType));
    await s.start();
    await _until(() => s.seriesEnd != null);
    expect(seen, containsAll([RoundStart, RacerProgress, VsRoundEnd, SeriesEnd, WordResult]));
    expect(s.lobby!.isVs, isTrue);
    expect(s.lobby!.series, 3);
    final end = s.seriesEnd!;
    expect(end.podium, hasLength(2));
    expect(end.podium.first.place, 1);
    expect(end.xp[rec.me]!.xp, 10, reason: 'the guest played 2 rounds and won none');
    expect(s.standings!.how, 'finished');
    expect(s.tally.values.reduce((a, b) => a + b), 2);
    // The guest forged one word in round 1 before the host finished.
    expect(s.mold!.cells, isNotEmpty);
  });

  test('a live co-op round replays into the app: claims, reveal, results', () async {
    final rec = _load('coop_round_host.json');
    final server = await _replay(rec.events);
    addTearDown(() => server.close(force: true));
    final s = CoopSession(
      client: RoomClient(baseUrl: 'http://127.0.0.1:${server.port}', code: 'LIVE', token: () async => 't'),
      me: rec.me,
    );
    addTearDown(s.dispose);
    await s.start();
    await _until(() => s.results != null);
    final r = s.results!;
    expect(r.completed, isTrue);
    expect(r.filled, r.total);
    expect(r.xp[rec.me]!.xp, greaterThan(0));
    expect(s.mold!.cells.every((c) => s.mold!.fillOf(c) != CellFill.empty), isTrue, reason: 'the mold is full');
    expect(s.scores.values.reduce((a, b) => a + b), r.teamScore);
  });
}
