import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:wordsmith/net/socket.dart';

/// A local WebSocket server; [answer] says whether it answers pings.
class _Server {
  _Server({this.answer = true});

  final bool answer;
  late HttpServer http;
  final sockets = <WebSocket>[];

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req, protocolSelector: (offered) => offered.first);
      sockets.add(ws);
      ws.listen((m) {
        if (answer && m == '{"op":"PING"}') ws.add('{"op":"PONG"}');
      });
    });
  }

  Uri get uri => Uri.parse('ws://127.0.0.1:${http.port}/');

  /// Goes away, connections and all.
  Future<void> close() async {
    await http.close(force: true);
    for (final ws in sockets) {
      await ws.close();
    }
  }
}

void main() {
  late _Server server;
  late Uri target;
  late ReconnectingSocket socket;
  var opened = 0;
  int? gaveUp;
  var giveUps = 0;

  ReconnectingSocket make() => ReconnectingSocket(
    uri: Uri.parse('ws://unused/'),
    token: () async => 'tok',
    onMessage: (_) {},
    onOpen: () => opened++,
    onGiveUp: (c) {
      giveUps++;
      gaveUp = c;
    },
    giveUpAfter: const Duration(milliseconds: 300),
    maxRetryDelay: const Duration(milliseconds: 50),
    wakeCheck: const Duration(milliseconds: 200),
    // The tests move the server; the socket keeps its address.
    connect: (_, protocols) => WebSocketChannel.connect(target, protocols: protocols),
  );

  Future<void> until(bool Function() ok, {String? reason}) async {
    for (var i = 0; i < 300 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ok(), isTrue, reason: reason);
  }

  setUp(() async {
    opened = 0;
    giveUps = 0;
    gaveUp = null;
    server = _Server();
    await server.start();
    target = server.uri;
    socket = make();
    await socket.start();
    await until(() => opened == 1);
  });

  tearDown(() async {
    await socket.stop();
    await server.close();
  });

  test('awake, it gives up once down past its window', () async {
    await server.close();
    await until(() => giveUps == 1, reason: 'gave up');
    expect(gaveUp, isNull);
  });

  test("asleep, it keeps trying past its window; awake, it's back at once", () async {
    socket.sleep();
    await server.close();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(giveUps, 0, reason: 'no giving up while the app is away');

    // The room is reachable again, and the app comes back.
    server = _Server();
    await server.start();
    target = server.uri;
    socket.wake();
    await until(() => opened == 2, reason: 'reconnected');
    expect(socket.connected, isTrue);
    expect(giveUps, 0);
  });

  test('back to a connection that still answers: kept', () async {
    socket.wake();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(opened, 1);
    expect(server.sockets, hasLength(1));
  });

  test('back to a connection that has gone quiet: replaced', () async {
    await socket.stop();
    await server.close();
    server = _Server(answer: false);
    await server.start();
    target = server.uri;
    socket = make();
    await socket.start();
    await until(() => opened == 2);
    socket.wake();
    await until(() => opened == 3, reason: 'a new connection');
    expect(server.sockets, hasLength(2));
    expect(giveUps, 0);
  });
}
