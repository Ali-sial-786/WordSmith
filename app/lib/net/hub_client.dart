import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Messages from the presence hub (server/src/hub/protocol.ts).
sealed class HubEvent {
  const HubEvent();

  static HubEvent? parse(Map<String, dynamic> m) => switch (m['op']) {
    'PRESENCE' => HubPresence(m['userId'] as String, m['status'] as String),
    'INVITE' => HubInvite(
      from: m['from'] as String,
      fromUsername: m['fromUsername'] as String? ?? '?',
      code: m['code'] as String,
      mode: m['mode'] as String,
    ),
    'OPEN_ROOMS' => HubOpenRooms((m['rooms'] as List?) ?? const []),
    'ERROR' => HubError(m['code'] as String? ?? 'unknown'),
    _ => null,
  };
}

class HubPresence extends HubEvent {
  const HubPresence(this.userId, this.status);

  final String userId;

  /// `online`, `solo`, `in_room:<CODE>` or `offline`.
  final String status;
}

class HubInvite extends HubEvent {
  const HubInvite({
    required this.from,
    required this.fromUsername,
    required this.code,
    required this.mode,
  });

  final String from;
  final String fromUsername;
  final String code;
  final String mode;
}

class HubOpenRooms extends HubEvent {
  const HubOpenRooms(this.rooms);
  final List<dynamic> rooms;
}

class HubError extends HubEvent {
  const HubError(this.code);
  final String code;
}

typedef SocketConnector = WebSocketChannel Function(Uri uri, Iterable<String> protocols);

/// Keeps one WebSocket to the hub open while signed in: reconnects with
/// backoff, sends keep-alives and re-sends the current status after a
/// reconnect.
class HubClient {
  HubClient({
    required this.baseUrl,
    required this.token,
    SocketConnector? connect,
  }) : _connect = connect ?? ((uri, protocols) => WebSocketChannel.connect(uri, protocols: protocols));

  final String baseUrl;
  final Future<String?> Function() token;
  final SocketConnector _connect;

  static const protocol = 'wordsmith.v1';
  static const _keepAlive = Duration(seconds: 30);

  final _events = StreamController<HubEvent>.broadcast();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _ping;
  Timer? _retry;
  int _attempt = 0;
  bool _running = false;
  String _status = 'online';

  Stream<HubEvent> get events => _events.stream;
  bool get connected => _channel != null;

  Uri get _uri {
    final base = Uri.parse(baseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/v1/ws/hub',
    );
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _open();
  }

  Future<void> _open() async {
    if (!_running) return;
    final t = await token();
    if (t == null) return;
    try {
      final channel = _connect(_uri, [protocol, t]);
      await channel.ready;
      _channel = channel;
      _attempt = 0;
      _sub = channel.stream.listen(_onMessage, onDone: _onClosed, onError: (_) => _onClosed());
      _ping = Timer.periodic(_keepAlive, (_) => _channel?.sink.add('{"op":"PING"}'));
      _send({'op': 'SET_STATUS', 'status': _status});
    } on Object catch (e) {
      debugPrint('hub connect failed: $e');
      _scheduleRetry();
    }
  }

  void _onMessage(dynamic data) {
    if (data is! String || data == '{"op":"PONG"}') return;
    try {
      final event = HubEvent.parse(jsonDecode(data) as Map<String, dynamic>);
      if (event != null) _events.add(event);
    } on Object catch (e) {
      debugPrint('hub message ignored: $e');
    }
  }

  void _onClosed() {
    final code = _channel?.closeCode;
    _teardown();
    // 4001: the account was deleted. Don't come back.
    if (_running && code != 4001) _scheduleRetry();
  }

  void _scheduleRetry() {
    if (!_running) return;
    final seconds = [1, 2, 4, 8, 15, 30][_attempt.clamp(0, 5)];
    _attempt++;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: seconds), _open);
  }

  void _teardown() {
    _ping?.cancel();
    _ping = null;
    _sub?.cancel();
    _sub = null;
    _channel = null;
  }

  void _send(Map<String, Object> message) => _channel?.sink.add(jsonEncode(message));

  /// `online`, `solo` or `in_room:<CODE>`.
  void setStatus(String status) {
    _status = status;
    _send({'op': 'SET_STATUS', 'status': status});
  }

  void invite(String to, String code, String mode) =>
      _send({'op': 'INVITE', 'to': to, 'code': code, 'mode': mode});

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    final channel = _channel;
    _teardown();
    await channel?.sink.close(1000);
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}
