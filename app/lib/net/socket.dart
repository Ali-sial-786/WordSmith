import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef SocketConnector = WebSocketChannel Function(Uri uri, Iterable<String> protocols);

WebSocketChannel defaultConnector(Uri uri, Iterable<String> protocols) =>
    WebSocketChannel.connect(uri, protocols: protocols);

/// A WebSocket to the Worker that authenticates with the Firebase token as a
/// subprotocol, keeps itself alive, and reconnects with backoff until
/// stopped (or closed with one of [stopCodes]).
class ReconnectingSocket {
  ReconnectingSocket({
    required this.uri,
    required this.token,
    required this.onMessage,
    this.onOpen,
    this.onDown,
    this.onGiveUp,
    this.shouldStop = _accountGone,
    this.giveUpAfter,
    this.maxRetryDelay = const Duration(seconds: 30),
    this.wakeCheck = const Duration(seconds: 4),
    SocketConnector? connect,
  }) : _connect = connect ?? defaultConnector;

  static const protocol = 'wordsmith.v1';
  static const _keepAlive = Duration(seconds: 30);

  final Uri uri;
  final Future<String?> Function() token;
  final void Function(String data) onMessage;

  /// After each successful (re)connect.
  final VoidCallback? onOpen;

  /// When a live connection drops (before any retry).
  final VoidCallback? onDown;

  /// When it stops retrying: [shouldStop] said so, or [giveUpAfter] passed.
  final void Function(int? closeCode)? onGiveUp;

  /// Close codes that mean "don't come back".
  final bool Function(int closeCode) shouldStop;

  static bool _accountGone(int code) => code == 4001;

  /// Stop retrying after being disconnected this long (null: never).
  final Duration? giveUpAfter;

  /// The longest wait between attempts (rooms keep it short so a dropped
  /// player is back well inside their 30 s seat window).
  final Duration maxRetryDelay;

  /// After [wake], how long a connection that looks up has to answer a ping
  /// before it's taken for dead and replaced.
  final Duration wakeCheck;
  final SocketConnector _connect;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _ping;
  Timer? _retry;
  int _attempt = 0;
  bool _running = false;
  bool _opening = false;
  bool _asleep = false;
  DateTime? _downSince;

  /// Whether anything has come in since the last [wake].
  bool _heard = false;
  Timer? _check;

  bool get connected => _channel != null;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _open();
  }

  Future<void> _open() async {
    if (!_running || _opening) return;
    _opening = true;
    try {
      // Inside the try: refreshing an expired token needs the network too.
      final t = await token();
      if (t == null) {
        _scheduleRetry(null);
        return;
      }
      final channel = _connect(uri, [protocol, t]);
      await channel.ready;
      if (!_running) {
        await channel.sink.close(1000);
        return;
      }
      _channel = channel;
      _attempt = 0;
      _downSince = null;
      _sub = channel.stream.listen(
        (data) {
          _heard = true;
          if (data is String && data != '{"op":"PONG"}') onMessage(data);
        },
        onDone: _onClosed,
        onError: (_) => _onClosed(),
      );
      _ping = Timer.periodic(_keepAlive, (_) => send('{"op":"PING"}'));
      onOpen?.call();
    } on Object catch (e) {
      debugPrint('socket connect failed ($uri): $e');
      _scheduleRetry(null);
    } finally {
      _opening = false;
    }
  }

  /// The app has gone to the background, where the phone may hold back its
  /// network for a while: retries go on, but [giveUpAfter] waits for [wake].
  void sleep() => _asleep = true;

  /// The app is back in front. Down: tries again now, with [giveUpAfter]
  /// counted afresh. Up: checks the connection still answers (one that died
  /// while the app was away can look up for minutes), and replaces it if not.
  void wake() {
    _asleep = false;
    if (!_running) return;
    if (_channel == null) {
      if (_opening) return;
      _retry?.cancel();
      _attempt = 0;
      _downSince = null;
      unawaited(_open());
      return;
    }
    _heard = false;
    send('{"op":"PING"}');
    _check?.cancel();
    _check = Timer(wakeCheck, () {
      final channel = _channel;
      if (_heard || channel == null || !_running) return;
      debugPrint('socket silent after waking ($uri): reconnecting');
      _onClosed();
      _attempt = 0;
      unawaited(channel.sink.close(1000).catchError((Object _) {}));
    });
  }

  void _onClosed() {
    final code = _channel?.closeCode;
    final wasUp = _channel != null;
    _teardown();
    if (!_running) return;
    if (wasUp) onDown?.call();
    if (code != null && shouldStop(code)) {
      _running = false;
      onGiveUp?.call(code);
      return;
    }
    _scheduleRetry(code);
  }

  void _scheduleRetry(int? code) {
    if (!_running) return;
    _downSince ??= DateTime.now();
    final limit = giveUpAfter;
    if (limit != null && !_asleep && DateTime.now().difference(_downSince!) > limit) {
      _running = false;
      onGiveUp?.call(code);
      return;
    }
    final seconds = [1, 2, 4, 8, 15, 30][_attempt.clamp(0, 5)];
    final delay = Duration(seconds: seconds) < maxRetryDelay ? Duration(seconds: seconds) : maxRetryDelay;
    _attempt++;
    _retry?.cancel();
    _retry = Timer(delay, _open);
  }

  void _teardown() {
    _ping?.cancel();
    _ping = null;
    _check?.cancel();
    _check = null;
    _sub?.cancel();
    _sub = null;
    _channel = null;
  }

  void send(String data) => _channel?.sink.add(data);

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    final channel = _channel;
    _teardown();
    await channel?.sink.close(1000);
  }
}
