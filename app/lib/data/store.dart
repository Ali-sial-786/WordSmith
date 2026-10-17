import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../engine/board.dart';
import '../engine/pickups.dart';
import '../engine/puzzle.dart';
import 'profile.dart';

/// A campaign puzzle the player has started but not finished.
class SavedPuzzle {
  const SavedPuzzle({
    required this.stage,
    required this.puzzleId,
    required this.letters,
    required this.foundSlots,
    required this.autoSlots,
    required this.revealed,
    required this.bonusFound,
    required this.pickups,
    required this.collected,
    required this.hintsUsed,
    required this.elapsedMs,
    required this.pickupSeed,
  });

  factory SavedPuzzle.fromBoard({
    required int stage,
    required Board board,
    required String letters,
    required Map<String, int> hintsUsed,
    required int elapsedMs,
    required String pickupSeed,
  }) => SavedPuzzle(
    stage: stage,
    puzzleId: board.puzzle.id,
    letters: letters,
    foundSlots: board.foundSlots.toList()..sort(),
    autoSlots: board.autoSlots.toList()..sort(),
    revealed: board.revealed.toList(),
    bonusFound: board.bonusFound.toList()..sort(),
    pickups: board.pickups,
    collected: board.collectedPickups.toList()..sort(),
    hintsUsed: hintsUsed,
    elapsedMs: elapsedMs,
    pickupSeed: pickupSeed,
  );

  factory SavedPuzzle.fromJson(Map<String, dynamic> json) => SavedPuzzle(
    stage: json['stage'] as int,
    puzzleId: json['puzzleId'] as String,
    letters: json['letters'] as String,
    foundSlots: (json['found'] as List).cast<int>(),
    autoSlots: (json['auto'] as List).cast<int>(),
    revealed: [
      for (final c in (json['revealed'] as List).cast<List>())
        (x: c[0] as int, y: c[1] as int),
    ],
    bonusFound: (json['bonus'] as List).cast<String>(),
    pickups: [
      for (final p in (json['pickups'] as List).cast<Map<String, dynamic>>())
        Pickup.fromJson(p),
    ],
    collected: (json['collected'] as List).cast<int>(),
    hintsUsed: (json['hintsUsed'] as Map).cast<String, int>(),
    elapsedMs: json['elapsedMs'] as int? ?? 0,
    pickupSeed: json['pickupSeed'] as String? ?? '',
  );

  final int stage;
  final String puzzleId;

  /// The tile letters (Turns only reorder them on screen).
  final String letters;
  final List<int> foundSlots;
  final List<int> autoSlots;
  final List<CellPos> revealed;
  final List<String> bonusFound;
  final List<Pickup> pickups;
  final List<int> collected;
  final Map<String, int> hintsUsed;
  final int elapsedMs;

  /// The id the pickups were seeded with (install id before sign-in).
  final String pickupSeed;

  /// Pickups collected so far in this puzzle.
  List<Pickup> get collectedPickups => [for (final i in collected) pickups[i]];

  Board toBoard(Puzzle puzzle) => Board(
    puzzle,
    foundSlots: foundSlots,
    autoSlots: autoSlots,
    revealed: revealed,
    bonusFound: bonusFound,
    pickups: pickups,
    collectedPickups: collected,
  );

  Map<String, Object> toJson() => {
    'stage': stage,
    'puzzleId': puzzleId,
    'letters': letters,
    'found': foundSlots,
    'auto': autoSlots,
    'revealed': [
      for (final c in revealed) [c.x, c.y],
    ],
    'bonus': bonusFound,
    'pickups': [for (final p in pickups) p.toJson()],
    'collected': collected,
    'hintsUsed': hintsUsed,
    'elapsedMs': elapsedMs,
    'pickupSeed': pickupSeed,
  };
}

/// Local persistence. Everything is small JSON in shared preferences.
class Store {
  Store(this._prefs);

  static Future<Store> open() async =>
      Store(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  static const _profileKey = 'profile.v1';
  static const _settingsKey = 'settings.v1';
  static const _savedKey = 'saved_puzzle.v1';
  static const _syncKey = 'sync_queue.v1';

  Profile loadProfile() {
    final raw = _prefs.getString(_profileKey);
    if (raw != null) {
      return Profile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
    final profile = Profile(userId: 'install-${_randomId()}');
    saveProfile(profile);
    return profile;
  }

  Future<void> saveProfile(Profile profile) =>
      _prefs.setString(_profileKey, jsonEncode(profile.toJson()));

  Settings loadSettings() {
    final raw = _prefs.getString(_settingsKey);
    return raw == null
        ? const Settings()
        : Settings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveSettings(Settings settings) =>
      _prefs.setString(_settingsKey, jsonEncode(settings.toJson()));

  SavedPuzzle? loadSavedPuzzle() {
    final raw = _prefs.getString(_savedKey);
    if (raw == null) return null;
    try {
      return SavedPuzzle.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  Future<void> savePuzzle(SavedPuzzle saved) =>
      _prefs.setString(_savedKey, jsonEncode(saved.toJson()));

  Future<void> clearSavedPuzzle() => _prefs.remove(_savedKey);

  /// Finished solo puzzles waiting to be sent to the server (M2).
  List<Map<String, dynamic>> loadSyncQueue() {
    final raw = _prefs.getString(_syncKey);
    return raw == null
        ? []
        : (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  Future<void> enqueueSync(Map<String, Object> entry) =>
      _prefs.setString(_syncKey, jsonEncode([...loadSyncQueue(), entry]));

  /// Drops the first [count] queued entries once the server has them.
  /// (Entries queued meanwhile stay.)
  Future<void> dropSynced(int count) {
    final queue = loadSyncQueue();
    return _prefs.setString(_syncKey, jsonEncode(queue.skip(count).toList()));
  }

  /// Forgets everything on this phone (after deleting the account).
  Future<void> clearAll() async {
    for (final key in [_profileKey, _savedKey, _syncKey]) {
      await _prefs.remove(key);
    }
  }

  static String _randomId() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
