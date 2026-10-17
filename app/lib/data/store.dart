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
    this.gilded,
    this.gildedCollected = false,
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
    gilded: board.gilded,
    gildedCollected: board.gildedCollected,
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
    gilded: json['gilded'] as int?,
    gildedCollected: json['gildedDone'] as bool? ?? false,
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

  /// The gilded cell, if any, and whether its piece was collected.
  final int? gilded;
  final bool gildedCollected;

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
    gilded: gilded,
    gildedCollected: gildedCollected,
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
    'gilded': ?gilded,
    'gildedDone': gildedCollected,
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
  static const _tipsKey = 'tips_seen.v1';
  static const _errorsKey = 'errors.v1';
  static const _crashSeenKey = 'crash_seen.v1';

  /// The last few app errors, oldest first, for crash reports.
  List<String> loadErrors() => _prefs.getStringList(_errorsKey) ?? const [];

  void addError(String error) {
    final all = [...loadErrors(), error];
    _prefs.setStringList(_errorsKey, all.sublist(max(0, all.length - 5)));
  }

  /// When the last crash the player was told about happened (ms).
  int get crashSeenAt => _prefs.getInt(_crashSeenKey) ?? 0;

  set crashSeenAt(int at) => _prefs.setInt(_crashSeenKey, at);

  static const _survivalKey = 'survival_queue.v1';
  static const _survivalOpenKey = 'survival_open.v1';
  static const _survivalBestKey = 'survival_best.v1';

  /// Finished Crucible runs waiting to be sent (shared/survival.md).
  List<Map<String, dynamic>> loadSurvivalQueue() {
    final raw = _prefs.getString(_survivalKey);
    return raw == null ? [] : (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  Future<void> enqueueSurvival(Map<String, Object?> run) =>
      _prefs.setString(_survivalKey, jsonEncode([...loadSurvivalQueue(), run]));

  Future<void> dropSurvival(String runId) => _prefs.setString(
    _survivalKey,
    jsonEncode(loadSurvivalQueue().where((r) => r['runId'] != runId).toList()),
  );

  /// The run being played right now, kept after every change.
  Future<void> saveOpenSurvival(Map<String, Object?>? run) =>
      run == null ? _prefs.remove(_survivalOpenKey) : _prefs.setString(_survivalOpenKey, jsonEncode(run));

  /// Queues a run the app was closed in the middle of.
  Future<void> closeOpenSurvival() async {
    final raw = _prefs.getString(_survivalOpenKey);
    if (raw == null) return;
    await _prefs.remove(_survivalOpenKey);
    final run = jsonDecode(raw) as Map<String, dynamic>;
    if (!loadSurvivalQueue().any((r) => r['runId'] == run['runId'])) await enqueueSurvival(run);
  }

  /// Hints spent in runs the server hasn't seen yet, by kind name.
  Map<String, int> pendingSurvivalHints() {
    final open = _prefs.getString(_survivalOpenKey);
    final runs = [...loadSurvivalQueue(), if (open != null) jsonDecode(open) as Map<String, dynamic>];
    final used = <String, int>{};
    for (final run in runs) {
      for (final p in (run['puzzles'] as List).cast<Map<String, dynamic>>()) {
        for (final e in (p['hintsUsed'] as Map).entries) {
          used[e.key as String] = (used[e.key] ?? 0) + (e.value as num).toInt();
        }
      }
    }
    return used;
  }

  /// The best Crucible run on this phone: {puzzles, words, saved, at}.
  Map<String, dynamic>? loadSurvivalBest() {
    final raw = _prefs.getString(_survivalBestKey);
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> saveSurvivalBest(Map<String, Object?> best) => _prefs.setString(_survivalBestKey, jsonEncode(best));

  /// One-time tips the player has already been shown.
  bool seenTip(String id) => _prefs.getStringList(_tipsKey)?.contains(id) ?? false;

  void markTip(String id) {
    final seen = _prefs.getStringList(_tipsKey) ?? const [];
    if (!seen.contains(id)) _prefs.setStringList(_tipsKey, [...seen, id]);
  }

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
    for (final key in [_profileKey, _savedKey, _syncKey, _survivalKey, _survivalOpenKey, _survivalBestKey]) {
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
