import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../net/room_client.dart';
import '../ui/mold/survival_overlay.dart' show meltDuration;
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

  // ---- Survival (shared/survival.md) ----

  /// The heated slot on my mold (the team's in co-op), while one is.
  HeatedSlot? heated;

  /// Heated words saved this round (the team's, or mine in Versus).
  int saved = 0;

  /// A word that melted, ending the round: the slot, whose mold (Versus),
  /// and when the melt has finished playing (this phone's clock).
  ({int slot, String? id, DateTime until})? melt;
  Timer? _meltDone;

  /// The round is (or was) a Survival one.
  bool get survival => round?.survival ?? lobby?.survival ?? false;

  /// The melt is still playing: the round view stays up until it's done.
  bool get melting => melt != null && DateTime.now().isBefore(melt!.until);

  /// How long the heated word has left, from the server's deadline.
  int get heatRemainingMs => heated == null ? 0 : max(0, heated!.deadline - serverNow);

  void _survival(RoomEvent e) {
    switch (e) {
      case RoundStart(:final heated):
        this.heated = heated;
        saved = heated?.saved ?? 0;
        melt = null;
      case HeatedSlot(:final saved, :final serverNow):
        heated = e;
        this.saved = saved;
        syncClock(serverNow);
      case Melted(:final slot, :final id):
        heated = null;
        melt = (slot: slot, id: id, until: DateTime.now().add(meltDuration + const Duration(milliseconds: 300)));
        _meltDone?.cancel();
        _meltDone = Timer(meltDuration + const Duration(milliseconds: 350), () {
          if (!_disposed) notifyListeners();
        });
      case RoomSnapshot(:final heated, :final saved):
        this.heated = heated;
        this.saved = saved;
      case RoundEnd() || VsRoundEnd():
        heated = null;
      default:
        break;
    }
  }

  Future<void> start() async {
    _subs
      ..add(client.events.listen(_onEvent))
      ..add(
        client.connection.listen((up) {
          connection = up ? RoomConnection.live : RoomConnection.reconnecting;
          notifyListeners();
        }),
      );
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

  /// My nickname for a player, if they're a friend I gave one; the room
  /// screen points it at the account's nicknames (game/names.dart).
  String? Function(String id) nicknameOf = _noNickname;

  static String? _noNickname(String _) => null;

  /// How a player is shown in this room: my nickname for them, else their
  /// username. Every view names players through this.
  String nameOf(String? id) {
    if (id == null) return 'The forge';
    return nicknameOf(id) ?? lobby?.player(id)?.username ?? departedName(id) ?? 'A smith';
  }

  Color colorOf(String? id) {
    final p = id == null ? null : lobby?.player(id);
    return p == null ? Palette.steel : Palette.player(p.color);
  }

  @protected
  void say(String text, Color color) {
    feed.insert(0, FeedLine(text, Palette.legible(color)));
    if (feed.length > 3) feed.removeLast();
  }

  void _onEvent(RoomEvent e) {
    final hostBefore = lobby?.hostId;
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
    _survival(e);
    _effects.add(e);
    // The host role came to me while I was in the room: say so.
    if (hostBefore != null && hostBefore != me && isHost) _effects.add(const BecameHost());
    notifyListeners();
  }

  /// This mode's events (everything but WELCOME and LOBBY).
  @protected
  void handle(RoomEvent e);

  // ---- Actions ----

  void setReady(bool ready) => client.ready(ready);

  /// Host only, in the lobby or results: `classic` or `survival`.
  void setVariant(String variant) => client.config(variant: variant);

  /// Host only, in the lobby or results: a heat tier 1–6, or null for Auto.
  void setHeat(int? tier) => client.config(heat: tier ?? 'auto');
  void startRound() => client.startRound();
  void again() => client.again();
  void emote(String id) => client.emote(id);
  Future<void> leave() => client.leave();

  @override
  void dispose() {
    _disposed = true;
    _meltDone?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _effects.close();
    client.dispose();
    super.dispose();
  }
}
