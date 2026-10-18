import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'socket.dart';

export 'socket.dart' show SocketConnector;

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
    'OPEN_ROOMS' => HubOpenRooms([
      for (final r in ((m['rooms'] as List?) ?? const []).cast<Map<String, dynamic>>()) OpenRoom.fromJson(r),
    ]),
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
  const HubInvite({required this.from, required this.fromUsername, required this.code, required this.mode});

  final String from;
  final String fromUsername;
  final String code;
  final String mode;
}

class HubOpenRooms extends HubEvent {
  const HubOpenRooms(this.rooms);
  final List<OpenRoom> rooms;
}

/// A friend's joinable room.
class OpenRoom {
  const OpenRoom({
    required this.code,
    required this.mode,
    required this.hostUsername,
    required this.players,
    required this.max,
    this.hostId = '',
  });

  factory OpenRoom.fromJson(Map<String, dynamic> j) => OpenRoom(
    code: j['code'] as String,
    mode: j['mode'] as String? ?? 'coop',
    hostId: j['hostId'] as String? ?? '',
    hostUsername: j['hostUsername'] as String? ?? '?',
    players: j['players'] as int? ?? 0,
    max: j['max'] as int? ?? 4,
  );

  final String code;
  final String mode;
  final String hostId;
  final String hostUsername;
  final int players;
  final int max;
}

class HubError extends HubEvent {
  const HubError(this.code);
  final String code;
}

/// Keeps one WebSocket to the hub open while signed in: reconnects with
/// backoff, sends keep-alives and re-sends the current status after a
/// reconnect.
class HubClient {
  HubClient({required String baseUrl, required Future<String?> Function() token, SocketConnector? connect}) {
    _socket = ReconnectingSocket(
      uri: wsUri(baseUrl, '/v1/ws/hub'),
      token: token,
      connect: connect,
      onOpen: () => _send({'op': 'SET_STATUS', 'status': _status}),
      onMessage: _onMessage,
    );
  }

  late final ReconnectingSocket _socket;
  final _events = StreamController<HubEvent>.broadcast();
  String _status = 'online';

  Stream<HubEvent> get events => _events.stream;
  bool get connected => _socket.connected;

  Future<void> start() => _socket.start();

  void _onMessage(String data) {
    try {
      final event = HubEvent.parse(jsonDecode(data) as Map<String, dynamic>);
      if (event != null) _events.add(event);
    } on Object catch (e) {
      debugPrint('hub message ignored: $e');
    }
  }

  void _send(Map<String, Object> message) => _socket.send(jsonEncode(message));

  /// `online`, `solo` or `in_room:<CODE>`.
  void setStatus(String status) {
    _status = status;
    _send({'op': 'SET_STATUS', 'status': status});
  }

  void invite(String to, String code, String mode) => _send({'op': 'INVITE', 'to': to, 'code': code, 'mode': mode});

  Future<void> stop() => _socket.stop();

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}

/// `https://host/base` + `/v1/ws/x` → `wss://host/base/v1/ws/x`.
Uri wsUri(String baseUrl, String path) {
  final base = Uri.parse(baseUrl);
  return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '${base.path}$path');
}
