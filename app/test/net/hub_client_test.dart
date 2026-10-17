import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/net/hub_client.dart';

/// A local stand-in for the hub that records what the client sends.
class _LocalHub {
  late HttpServer server;
  final received = <String>[];
  final protocols = <String?>[];
  final sockets = <WebSocket>[];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      protocols.add(req.headers.value('sec-websocket-protocol'));
      final ws = await WebSocketTransformer.upgrade(
        req,
        protocolSelector: (offered) => offered.first,
      );
      sockets.add(ws);
      ws.listen((m) => received.add(m as String));
    });
  }

  String get base => 'http://127.0.0.1:${server.port}';
}

void main() {
  late _LocalHub hub;
  late HubClient client;

  setUp(() async {
    hub = _LocalHub();
    await hub.start();
    client = HubClient(baseUrl: hub.base, token: () async => 'tok123');
  });

  tearDown(() async {
    await client.dispose();
    await hub.server.close(force: true);
  });

  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 100 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ok(), isTrue);
  }

  test('connects with the token as a subprotocol and announces its status', () async {
    await client.start();
    await until(() => hub.received.isNotEmpty);
    expect(hub.protocols.single, 'wordsmith.v1, tok123');
    expect(jsonDecode(hub.received.first), {'op': 'SET_STATUS', 'status': 'online'});

    client.setStatus('solo');
    await until(() => hub.received.length == 2);
    expect(jsonDecode(hub.received.last), {'op': 'SET_STATUS', 'status': 'solo'});
  });

  test('turns hub messages into events', () async {
    final events = <HubEvent>[];
    client.events.listen(events.add);
    await client.start();
    await until(() => hub.sockets.isNotEmpty);
    hub.sockets.single
      ..add(jsonEncode({'op': 'PRESENCE', 'userId': 'u2', 'status': 'solo'}))
      ..add('{"op":"PONG"}')
      ..add(jsonEncode({'op': 'INVITE', 'from': 'u2', 'fromUsername': 'Sam', 'code': 'K7Q2AB', 'mode': 'coop'}));
    await until(() => events.length == 2);
    final presence = events.first as HubPresence;
    expect((presence.userId, presence.status), ('u2', 'solo'));
    final invite = events.last as HubInvite;
    expect((invite.fromUsername, invite.code, invite.mode), ('Sam', 'K7Q2AB', 'coop'));
  });

  test('reconnects after the connection drops and re-sends its status', () async {
    await client.start();
    client.setStatus('solo');
    await until(() => hub.received.length == 2);
    await hub.sockets.single.close(1011);
    await until(() => hub.sockets.length == 2);
    await until(() => hub.received.length == 3);
    expect(jsonDecode(hub.received.last), {'op': 'SET_STATUS', 'status': 'solo'});
  });

  test('stays away after the account is deleted (close code 4001)', () async {
    await client.start();
    await until(() => hub.sockets.isNotEmpty);
    await hub.sockets.single.close(4001);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(hub.sockets, hasLength(1));
  });

  test('keeps trying when there is no token yet, then connects', () async {
    await client.dispose();
    var calls = 0;
    client = HubClient(baseUrl: hub.base, token: () async => ++calls < 2 ? null : 'tok123');
    await client.start();
    await until(() => hub.received.isNotEmpty);
    expect(calls, greaterThanOrEqualTo(2));
  });
}
