import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../net/room_client.dart';
import '../ui/theme/palette.dart';

enum RoomConnection { connecting, live, reconnecting, closed }

/// One line in the round's live feed.
class FeedLine {
  const FeedLine(this.text, this.color);
  final String text;
  final Color color;
}

/// What every room shares on this phone: the connection, lobby, clock and the
/// lobby actions. [CoopSession] and [VsSession] add their mode's rules. The
/// screen listens to it, and to [effects] for one-off sounds and animations.
abstract class RoomSession extends ChangeNotifier {
  RoomSession({required this.client, required this.me});

  final RoomClient client;

  /// The signed-in player's id.
  String me;

  RoomConnection connection = RoomConnection.connecting;
  int? closeCode;
  RoomLobby? lobby;
  RoundStart? round;
  final List<FeedLine> feed = [];

  /// serverNow − localNow, from the latest message that carried it.
  int clockOffsetMs = 0;
  final _effects = StreamController<RoomEvent>.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];
  bool _disposed = false;

  /// Claims, word results, reveals, emotes, errors: for sounds and sparks.
  Stream<RoomEvent> get effects => _effects.stream;

  bool get isHost => lobby?.hostId == me;

  /// A ROUND_START can arrive a moment before the LOBBY that moves the phase
  /// on; until then, act as if the countdown has begun (no lobby flash).
  String? _phaseAhead;

  String get phase => _phaseAhead ?? lobby?.phase ?? 'lobby';
  RoomPlayer? get myPlayer => lobby?.player(me);

  int get serverNow => DateTime.now().millisecondsSinceEpoch + clockOffsetMs;

  Duration get timeLeft =>
      round == null ? Duration.zero : Duration(milliseconds: (round!.endsAt - serverNow).clamp(0, 1 << 31));

  Duration get countdownLeft =>
      round == null ? Duration.zero : Duration(milliseconds: (round!.startsAt - serverNow).clamp(0, 1 << 31));

  Future<void> start() async {
    _subs
      ..add(client.events.listen(_onEvent))
      ..add(client.connection.listen((up) {
        connection = up ? RoomConnection.live : RoomConnection.reconnecting;
        notifyListeners();
      }));
    unawaited(
      client.closed.then((code) {
        if (_disposed) return;
        connection = RoomConnection.closed;
        closeCode = code;
        notifyListeners();
      }),
    );
    await client.start();
  }

  @protected
  void syncClock(int serverNow) {
    if (serverNow > 0) clockOffsetMs = serverNow - DateTime.now().millisecondsSinceEpoch;
  }

  /// A name for players who have left the room, if this mode remembers one.
  @protected
  String? departedName(String id) => null;

  String nameOf(String? id) {
    if (id == null) return 'The forge';
    return lobby?.player(id)?.username ?? departedName(id) ?? 'A smith';
  }

  Color colorOf(String? id) {
    final p = id == null ? null : lobby?.player(id);
    return p == null ? Palette.steel : Palette.player(p.color);
  }

  @protected
  void say(String text, Color color) {
    feed.insert(0, FeedLine(text, color));
    if (feed.length > 3) feed.removeLast();
  }

  void _onEvent(RoomEvent e) {
    switch (e) {
      case RoomWelcome(:final you, :final serverNow):
        me = you;
        syncClock(serverNow);
      case RoomLobby():
        lobby = e;
        _phaseAhead = null;
      case RoundStart():
        if (lobby?.phase != 'countdown' && lobby?.phase != 'round') _phaseAhead = 'countdown';
        handle(e);
      case RoomSnapshot():
        _phaseAhead = null;
        handle(e);
      default:
        handle(e);
    }
    _effects.add(e);
    notifyListeners();
  }

  /// This mode's events (everything but WELCOME and LOBBY).
  @protected
  void handle(RoomEvent e);

  // ---- Actions ----

  void setReady(bool ready) => client.ready(ready);
  void startRound() => client.startRound();
  void again() => client.again();
  void emote(String id) => client.emote(id);
  Future<void> leave() => client.leave();

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    _effects.close();
    client.dispose();
    super.dispose();
  }
}
