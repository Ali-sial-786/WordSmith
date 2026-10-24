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

  // ---- Chat ----

  /// The room's chat as this phone has it, oldest first (the server keeps
  /// the latest 50 for anyone joining; this keeps up to [_chatKept]).
  final List<ChatLine> chat = [];
  static const _chatKept = 100;

  /// Shows the chat button, its count and new lines (Settings); lines still
  /// arrive while it's off, so turning it on shows what was said.
  bool chatEnabled = true;

  /// The chat is open on screen: new lines count as read.
  bool get chatOpen => _chatOpen;
  bool _chatOpen = false;

  /// Lines up to this id have been seen. What was said before I joined
  /// isn't news; what came while I was reconnecting is.
  int _readUpTo = 0;
  bool _chatJoined = false;

  /// Players whose lines I've hidden in this room.
  final Set<String> muted = {};

  /// Whether I've blocked a player (everywhere); the room screen points it
  /// at the account's block list (shared/safety.md).
  bool Function(String id) isBlocked = _notBlocked;

  static bool _notBlocked(String _) => false;

  /// I don't see [id]'s chat or emotes: muted here, or blocked.
  bool hides(String id) => muted.contains(id) || isBlocked(id);

  /// Lines I can see: not from a player I've muted or blocked.
  List<ChatLine> get visibleChat => [
    for (final l in chat)
      if (!hides(l.from)) l,
  ];

  /// Lines from others that came since I last looked.
  int get unreadChat => chat.where((l) => l.id > _readUpTo && l.from != me && !hides(l.from)).length;

  /// A line's sender as I know them, even if they've left the room.
  String chatName(ChatLine line) =>
      nicknameOf(line.from) ?? lobby?.player(line.from)?.username ?? departedName(line.from) ?? line.username;

  void _addChat(Iterable<ChatLine> lines) {
    final known = {for (final l in chat) l.id};
    chat
      ..addAll(lines.where((l) => !known.contains(l.id)))
      ..sort((a, b) => a.id.compareTo(b.id));
    if (chat.length > _chatKept) chat.removeRange(0, chat.length - _chatKept);
    if (_chatOpen || !_chatJoined) _readUpTo = chat.isEmpty ? 0 : chat.last.id;
    _chatJoined = true;
  }

  void openChat() {
    _chatOpen = true;
    if (chat.isNotEmpty) _readUpTo = chat.last.id;
    notifyListeners();
  }

  void closeChat() {
    _chatOpen = false;
    if (!_disposed) notifyListeners();
  }

  /// Sends a line; the server tidies it, stars out profanity and sends it to everyone, me too.
  void sendChat(String text) {
    final line = text.trim();
    if (line.isNotEmpty) client.chat(line);
  }

  void mute(String id) {
    muted.add(id);
    notifyListeners();
  }

  void unmute(String id) {
    muted.remove(id);
    notifyListeners();
  }

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
      case RoomSnapshot(:final chat):
        _phaseAhead = null;
        _addChat(chat);
        handle(e);
      case RoomChat(:final line):
        _addChat([line]);
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

  /// Ready for the next round, between rounds: everyone ready starts it sooner.
  void readyForNext() => client.next();
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
