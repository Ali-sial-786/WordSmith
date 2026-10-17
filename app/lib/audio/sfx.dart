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
  tick('tick');

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
  Settings _settings;

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
  }

  double get _ambienceVolume => _settings.ambienceVolume * 0.6;

  void play(SfxId id, {double volume = 1}) => _play(id.file, volume);

  /// Tile-touch tink for the [n]th letter of the current word (1-based);
  /// the pitch rises with each tile.
  void tink(int n) => _play('tink_${n.clamp(1, tinkCount)}', 0.8);

  void _play(String file, double volume) {
    if (!_enabled || _settings.sfxVolume <= 0) return;
    _voices[file]?.play(volume * _settings.sfxVolume).catchError((Object e) {
      debugPrint('sound $file failed: $e');
    });
  }

  Future<void> startAmbience() async {
    if (!_enabled || _ambience != null) return;
    try {
      final player = AudioPlayer();
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(_ambienceVolume);
      await player.play(AssetSource('audio/forge_ambience.ogg'));
      _ambience = player;
    } on Object catch (e) {
      debugPrint('ambience unavailable: $e');
    }
  }
}
