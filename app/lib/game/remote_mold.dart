import 'package:flutter/painting.dart';

import '../engine/puzzle.dart';
import '../net/room_client.dart';
import '../ui/mold/mold_model.dart';
import '../ui/theme/palette.dart';

/// A room's mold as the server has revealed it: slot shapes from the start,
/// letters only once forged, hinted or shown in the results. Co-op shares one
/// between the team; in Versus it's this player's own.
class RemoteMold implements MoldModel {
  RemoteMold(RoundStart start, this._players, {this.initials = true, this.nameOf})
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

  /// Mark each forged word with its smith's initial (co-op; in Versus
  /// every word on your mold is yours).
  final bool initials;

  /// A player's name as I see them (the session's `nameOf`), for initials;
  /// their username if not given.
  final String Function(String id)? nameOf;

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

  /// The words through [cell] whose letters are all known, to look up.
  List<String> wordsAt(CellPos cell) => [
    for (final i in _slotsAt[cell] ?? const <int>[])
      if (slot(i).cells.every((c) => (_letters[c] ?? '').isNotEmpty)) slot(i).cells.map((c) => _letters[c]).join(),
  ];

  bool isClaimed(int slot) => _owner.containsKey(slot);

  /// Slot → who forged it (null: it filled in by itself).
  Map<int, String?> get owners => Map.unmodifiable(_owner);

  /// Cells a hint showed.
  Set<CellPos> get revealedCells => Set.unmodifiable(_revealed);
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

  @override
  bool isGilded(CellPos cell) => false;

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
    return p == null ? null : Palette.player(p.color);
  }

  @override
  String? ownerInitial(CellPos cell) {
    if (!initials) return null;
    for (final e in _owner.entries) {
      if (e.value == null) continue;
      final s = slot(e.key);
      if (s.cells.first == cell) {
        final player = _players().player(e.value!);
        final name = player == null ? '' : nameOf?.call(player.id) ?? player.username;
        // A whole code point, so a nickname starting with an emoji keeps it.
        return name.isEmpty ? null : String.fromCharCode(name.runes.first).toUpperCase();
      }
    }
    return null;
  }
}
