import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// A hub or room socket with no network, for a `SocketConnector`: the test
/// says what the server sends, and reads what the app [sent].
class FakeSocketChannel implements WebSocketChannel {
  final _incoming = StreamController<dynamic>();
  final sent = <String>[];

  /// The server sends [message].
  void receive(Map<String, Object?> message) => _incoming.add(jsonEncode(message));

  @override
  Future<void> get ready => Future.value();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _FakeSink(this);

  @override
  int? get closeCode => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._channel);

  final FakeSocketChannel _channel;

  @override
  void add(dynamic data) => _channel.sent.add(data as String);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
