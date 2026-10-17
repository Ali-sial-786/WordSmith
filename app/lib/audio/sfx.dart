import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../data/profile.dart';

enum SfxId {
  clang('clang'),
  clangLight('clang_light'),
  bonus('bonus'),
  already('already'),
  invalid('invalid'),
  hintHammer('hint_hammer'),
  hintChisel('hint_chisel'),
  hintSparks('hint_sparks'),
  pickup('pickup'),
  forged('forged'),
  levelUp('levelup'),
  shuffle('shuffle'),
  tap('tap'),
  tick('tick'),
  roundWin('round_win'),
  roundLose('round_lose'),
  seriesWin('series_win'),
  rivalFinished('rival_finished'),
  gilded('gilded'),
  masterwork('masterwork'),
  claim('claim'),
  page('page');

  const SfxId(this.file);
  final String file;
}

/// A few low-latency players for one sound, used round-robin so a sound can
/// overlap itself (fast swipes, quick words).
class _Voice {
  _Voice(this._players);

  final List<AudioPlayer> _players;
  int _next = 0;

  static Future<_Voice> load(String file, int count) async {
    final players = <AudioPlayer>[];
    for (var i = 0; i < count; i++) {
      final p = AudioPlayer();
      if (!kIsWeb) await p.setPlayerMode(PlayerMode.lowLatency);
      await p.setReleaseMode(ReleaseMode.stop);
      await p.setSource(AssetSource('audio/$file.ogg'));
      players.add(p);
    }
    return _Voice(players);
  }

  Future<void> play(double volume) async {
    final p = _players[_next];
    _next = (_next + 1) % _players.length;
    await p.stop();
    await p.setVolume(volume);
    await p.resume();
  }
}

/// Sound effects and the forge ambience loop. Every call is fire-and-forget
/// and failures are swallowed: a missing sound must never break the game.
class Sfx {
  Sfx({required this._enabled, this._settings = const Settings()});

  factory Sfx.silent() => Sfx(enabled: false);

  static const tinkCount = 8;

  final bool _enabled;
  final Map<String, _Voice> _voices = {};
  AudioPlayer? _ambience;
  AudioPlayer? _music;
  String? _track;
  Settings _settings;

  /// The app is off screen (home button, recents, another app): nothing
  /// plays until it's back.
  bool _away = false;

  /// Loads every sound in the background; sounds play once loaded.
  Future<void> preload() async {
    if (!_enabled) return;
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build(),
      );
    } on Object catch (e) {
      debugPrint('audio context: $e');
    }
    Future<void> loadOne(String file, int count) async {
      try {
        _voices[file] = await _Voice.load(file, count);
      } on Object catch (e) {
        debugPrint('sound $file unavailable: $e');
      }
    }

    await Future.wait([
      for (var i = 1; i <= tinkCount; i++) loadOne('tink_$i', 2),
      for (final id in SfxId.values) loadOne(id.file, 2),
    ]);
  }

  void applySettings(Settings settings) {
    _settings = settings;
    _ambience?.setVolume(_ambienceVolume).ignore();
    _music?.setVolume(_musicVolume).ignore();
  }

  double get _ambienceVolume => _settings.ambienceVolume * 0.6;
  double get _musicVolume => _settings.musicVolume * 0.45;

  /// Loops a music track from assets/audio (`music_hall`, `music_round`), or
  /// stops the music with null. Switching to the playing track does nothing.
  Future<void> music(String? track) async {
    if (!_enabled || track == _track) return;
    _track = track;
    try {
      final player = _music ??= AudioPlayer();
      await player.stop();
      if (track == null) return;
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(_musicVolume);
      await player.setSource(AssetSource('audio/$track.ogg'));
      if (!_away) await player.resume();
    } on Object catch (e) {
      debugPrint('music $track unavailable: $e');
    }
  }

  void play(SfxId id, {double volume = 1}) => _play(id.file, volume);

  /// Tile-touch tink for the [n]th letter of the current word (1-based);
  /// the pitch rises with each tile.
  void tink(int n) => _play('tink_${n.clamp(1, tinkCount)}', 0.8);

  void _play(String file, double volume) {
    if (!_enabled || _away || _settings.sfxVolume <= 0) return;
    _voices[file]?.play(volume * _settings.sfxVolume).catchError((Object e) {
      debugPrint('sound $file failed: $e');
    });
  }

  Future<void> startAmbience() async {
    if (!_enabled || _ambience != null) return;
    try {
      final player = AudioPlayer();
      _ambience = player;
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(_ambienceVolume);
      await player.setSource(AssetSource('audio/forge_ambience.ogg'));
      if (!_away) await player.resume();
    } on Object catch (e) {
      debugPrint('ambience unavailable: $e');
    }
  }

  /// Pauses the music and ambience while the app is off screen ([away]),
  /// and picks them up again when it's back.
  Future<void> setAway(bool away) async {
    if (!_enabled || away == _away) return;
    _away = away;
    try {
      if (away) {
        await _music?.pause();
        await _ambience?.pause();
      } else {
        if (_track != null) await _music?.resume();
        await _ambience?.resume();
      }
    } on Object catch (e) {
      debugPrint('audio ${away ? 'pause' : 'resume'}: $e');
    }
  }

  /// The app is closing: stop everything for good.
  Future<void> shutDown() async {
    _away = true;
    for (final p in [_music, _ambience]) {
      try {
        await p?.stop();
        await p?.release();
      } on Object catch (e) {
        debugPrint('audio shut down: $e');
      }
    }
  }
}
