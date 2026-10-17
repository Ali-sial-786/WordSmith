import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../engine/puzzle.dart';
import '../net/room_client.dart';
import '../ui/mold/mold_model.dart';
import '../ui/theme/palette.dart';

/// The co-op mold as the server has revealed it: slot shapes from the start,
/// letters only once forged, hinted or shown in the results.
class RemoteMold implements MoldModel {
  RemoteMold(RoundStart start, this._players)
    : cols = start.cols,
      rows = start.rows,
      slots = start.slots,
      _pickups = {...start.pickups} {
    final seen = <CellPos>{};
    for (final s in slots) {
      for (final c in s.cells) {
        if (seen.add(c)) _cells.add(c);
        (_slotsAt[c] ??= []).add(s.slot);
      }
    }
    _cells.sort((a, b) => a.y != b.y ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
  }

  @override
  final int cols;
  @override
  final int rows;
  final List<RemoteSlot> slots;
  final List<CellPos> _cells = [];
  final Map<CellPos, List<int>> _slotsAt = {};
  final Map<CellPos, String> _letters = {};

  /// Slot → who forged it (in claim order); auto-filled slots map to null.
  final Map<int, String?> _owner = {};
  final Set<CellPos> _revealed = {};
  final Set<CellPos> _pickups;

  /// Answers shown after the round, not forged by anyone.
  final Set<int> _missed = {};
  RoomLobby Function() _players;

  set players(RoomLobby Function() lookup) => _players = lookup;

  @override
  List<CellPos> get cells => _cells;

  RemoteSlot slot(int i) => slots.firstWhere((s) => s.slot == i);

  bool isClaimed(int slot) => _owner.containsKey(slot);
  int get claimedCount => _owner.length;
  bool get complete => _owner.length == slots.length;
  int get filledLetters => _cells.where((c) => fillOf(c) != CellFill.empty).length;

  /// Applies a forged (or auto-filled) word; returns its newly shown cells.
  List<CellPos> claim(int slotIndex, String word, String? by) {
    final s = slot(slotIndex);
    final fresh = <CellPos>[];
    final cells = s.cells;
    for (var i = 0; i < cells.length && i < word.length; i++) {
      if (fillOf(cells[i]) != CellFill.filled) fresh.add(cells[i]);
      _letters[cells[i]] = word[i];
    }
    _owner.putIfAbsent(slotIndex, () => by);
    for (final c in cells) {
      _pickups.remove(c);
    }
    return fresh;
  }

  void reveal(List<(CellPos, String)> cells) {
    for (final (c, letter) in cells) {
      _letters[c] = letter;
      _revealed.add(c);
    }
  }

  /// After the round: show every answer; ones nobody forged stay unclaimed.
  void showAnswers(List<(int, String)> answers) {
    for (final (slotIndex, word) in answers) {
      if (_owner.containsKey(slotIndex)) continue;
      _missed.add(slotIndex);
      final cells = slot(slotIndex).cells;
      for (var i = 0; i < cells.length && i < word.length; i++) {
        _letters[cells[i]] = word[i];
      }
    }
  }

  @override
  String letterAt(CellPos cell) => _letters[cell] ?? '';

  @override
  CellFill fillOf(CellPos cell) {
    final through = _slotsAt[cell] ?? const [];
    if (through.any(_owner.containsKey)) return CellFill.filled;
    if (_revealed.contains(cell) || through.any(_missed.contains)) return CellFill.revealed;
    return CellFill.empty;
  }

  @override
  String? pickupAt(CellPos cell) => _pickups.contains(cell) ? 'ember' : null;

  String? _ownerOf(CellPos cell) {
    for (final e in _owner.entries) {
      if (e.value != null && (_slotsAt[cell] ?? const []).contains(e.key)) return e.value;
    }
    return null;
  }

  @override
  Color? ownerColor(CellPos cell) {
    final id = _ownerOf(cell);
    final p = id == null ? null : _players().player(id);
    return p == null ? null : Palette.players[p.color % 4];
  }

  @override
  String? ownerInitial(CellPos cell) {
    for (final e in _owner.entries) {
      if (e.value == null) continue;
      final s = slot(e.key);
      if (s.cells.first == cell) {
        final name = _players().player(e.value!)?.username ?? '';
        return name.isEmpty ? null : name[0].toUpperCase();
      }
    }
    return null;
  }
}

enum RoomConnection { connecting, live, reconnecting, closed }

/// One line in the round's live feed.
class FeedLine {
  const FeedLine(this.text, this.color);
  final String text;
  final Color color;
}

/// Everything about one co-op room on this phone: lobby, round, results.
/// The screen listens to it and to [effects] for one-off animations.
class CoopSession extends ChangeNotifier {
  CoopSession({required this.client, required this.me});

  final RoomClient client;

  /// The signed-in player's id.
  String me;

  RoomConnection connection = RoomConnection.connecting;
  int? closeCode;
  RoomLobby? lobby;
  RoundStart? round;
  RemoteMold? mold;
  RoundEnd? results;
  Map<String, int> scores = {};
  final List<FeedLine> feed = [];

  /// serverNow − localNow, from the latest message that carried it.
  int clockOffsetMs = 0;
  final Map<int, String> _pending = {};
  final _effects = StreamController<RoomEvent>.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];
  bool _disposed = false;

  /// Claims, word results, reveals, emotes, errors: for sounds and sparks.
  Stream<RoomEvent> get effects => _effects.stream;

  bool get isHost => lobby?.hostId == me;
  String get phase => lobby?.phase ?? 'lobby';
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

  void _syncClock(int serverNow) {
    if (serverNow > 0) clockOffsetMs = serverNow - DateTime.now().millisecondsSinceEpoch;
  }

  String nameOf(String? id) =>
      id == null ? 'The forge' : (lobby?.player(id)?.username ?? 'A smith');

  Color colorOf(String? id) {
    final p = id == null ? null : lobby?.player(id);
    return p == null ? Palette.steel : Palette.players[p.color % 4];
  }

  void _say(String text, Color color) {
    feed.insert(0, FeedLine(text, color));
    if (feed.length > 3) feed.removeLast();
  }

  void _beginRound(RoundStart start) {
    round = start;
    results = null;
    scores = {};
    feed.clear();
    mold = RemoteMold(start, () => lobby!);
    _syncClock(start.serverNow);
  }

  void _onEvent(RoomEvent e) {
    switch (e) {
      case RoomWelcome(:final you, :final serverNow):
        me = you;
        _syncClock(serverNow);
      case RoomLobby():
        lobby = e;
      case RoundStart():
        _beginRound(e);
      case WordClaimed(:final slot, :final word, :final by, :final points, :final auto):
        mold?.claim(slot, word, by);
        for (final (s, w) in auto) {
          mold?.claim(s, w, null);
        }
        scores = e.scores;
        _say('${nameOf(by)} forged $word  +$points', colorOf(by));
      case BonusClaimed(:final word, :final by, :final points):
        scores = e.scores;
        _say('${nameOf(by)} found bonus $word  +$points', colorOf(by));
      case Revealed(:final cells, :final auto, :final by):
        mold?.reveal(cells);
        for (final (s, w) in auto) {
          mold?.claim(s, w, null);
        }
        _say('${nameOf(by)} used a ${e.kind == 'hammer' ? 'Hammer Strike' : e.kind == 'chisel' ? 'Chisel' : 'Spark Shower'}', colorOf(by));
      case RoundEnd(:final answers):
        results = e;
        mold?.showAnswers(answers);
      case RoomSnapshot():
        _applySnapshot(e);
      case WordResult(:final seq):
        _pending.remove(seq);
      case RoomEmote() || RoomError():
        break;
    }
    _effects.add(e);
    notifyListeners();
  }

  void _applySnapshot(RoomSnapshot s) {
    lobby = s.lobby;
    if (s.round != null) {
      _beginRound(s.round!);
      for (final (slot, word, by) in s.claims) {
        mold!.claim(slot, word, by);
      }
      for (final (slot, word) in s.auto) {
        mold!.claim(slot, word, null);
      }
      mold!.reveal(s.revealed);
      scores = s.scores;
    }
    if (s.results != null) {
      results = s.results;
      mold?.showAnswers(s.results!.answers);
    }
  }

  // ---- Actions ----

  void setReady(bool ready) => client.ready(ready);
  void startRound() => client.startRound();
  void again() => client.again();
  void emote(String id) => client.emote(id);

  /// Sends a word; the result arrives as a [WordResult] effect.
  void submit(String word) {
    final seq = client.submit(word);
    _pending[seq] = word;
  }

  void hint(String kind, {CellPos? cell}) => client.hint(kind, cell: cell);

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
