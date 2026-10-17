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

/// Sound effects and the forge ambience loop. Every call is fire-and-forget
/// and failures are swallowed: a missing sound must never break the game.
class Sfx {
  Sfx._(this._enabled);

  factory Sfx.silent() => Sfx._(false);

  static const tinkCount = 8;

  final bool _enabled;
  final Map<String, AudioPool> _pools = {};
  AudioPlayer? _ambience;
  Settings _settings = const Settings();

  static Future<Sfx> load(Settings settings) async {
    final sfx = Sfx._(true).._settings = settings;
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build(),
      );
    } on Object catch (e) {
      debugPrint('audio context: $e');
    }
    final files = [
      for (var i = 1; i <= tinkCount; i++) 'tink_$i',
      for (final id in SfxId.values) id.file,
    ];
    Future<void> loadOne(String file) async {
      try {
        sfx._pools[file] = await AudioPool.createFromAsset(
          path: 'audio/$file.ogg',
          maxPlayers: file.startsWith('tink') ? 2 : 3,
        );
      } on Object catch (e) {
        debugPrint('sound $file unavailable: $e');
      }
    }

    await Future.wait(files.map(loadOne));
    return sfx;
  }

  void applySettings(Settings settings) {
    _settings = settings;
    _ambience?.setVolume(settings.ambienceVolume * 0.6).ignore();
  }

  void play(SfxId id, {double volume = 1}) => _play(id.file, volume);

  /// Tile-touch tink for the [n]th letter of the current word (1-based);
  /// the pitch rises with each tile.
  void tink(int n) => _play('tink_${n.clamp(1, tinkCount)}', 0.8);

  void _play(String file, double volume) {
    if (!_enabled || _settings.sfxVolume <= 0) return;
    final pool = _pools[file];
    if (pool == null) return;
    pool.start(volume: volume * _settings.sfxVolume).ignore();
  }

  Future<void> startAmbience() async {
    if (!_enabled || _ambience != null) return;
    try {
      final player = AudioPlayer();
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(_settings.ambienceVolume * 0.6);
      await player.play(AssetSource('audio/forge_ambience.ogg'));
      _ambience = player;
    } on Object catch (e) {
      debugPrint('ambience unavailable: $e');
    }
  }
}
