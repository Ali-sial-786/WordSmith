import 'dart:ui' show AppLifecycleState;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../data/profile.dart';
import 'background_audio.dart';
import 'web_sound.dart';

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
  page('page'),
  melt('melt'),
  swing('swing');

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
  /// [newPlayer] and [background] are swapped out in tests.
  Sfx({
    required this._enabled,
    this._settings = const Settings(),
    this._newPlayer = AudioPlayer.new,
    this._background = const BackgroundAudio(),
  }) {
    if (_enabled) _background.listen(_onInterruption);
  }

  factory Sfx.silent() => Sfx(enabled: false);

  static const tinkCount = 8;

  final bool _enabled;
  final AudioPlayer Function() _newPlayer;
  final BackgroundAudio _background;
  final Map<String, _Voice> _voices = {};
  AudioPlayer? _ambience;
  AudioPlayer? _music;

  /// In the browser, its own engine instead of audioplayers (web_sound.dart).
  WebSound? _web;
  bool _webAmbience = false;
  String? _track;
  Settings _settings;

  /// The app is off screen (home button, recents, another app, screen off).
  bool _offScreen = false;

  /// Nothing plays: off screen without background play, or closing.
  bool _away = false;

  /// Off screen, a phone call or another app's audio has taken over.
  bool _interrupted = false;

  bool get _quiet => _away || _interrupted;

  /// What Android was last told: the music and ambience carry on off screen.
  bool _keepPlaying = false;

  /// Loads every sound in the background; sounds play once loaded.
  Future<void> preload() async {
    if (!_enabled) return;
    if (kIsWeb && WebSound.supported) {
      final web = _web = WebSound();
      await web.load([for (var i = 1; i <= tinkCount; i++) 'tink_$i', for (final id in SfxId.values) id.file]);
      return;
    }
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
    _web
      ?..setLoopVolume('music', _musicVolume)
      ..setLoopVolume('ambience', _ambienceVolume);
    _syncBackground();
  }

  double get _ambienceVolume => _settings.ambienceVolume * 0.6;
  double get _musicVolume => _settings.musicVolume * 0.45;

  /// Loops a music track from assets/audio (`music_hall`, `music_round`), or
  /// stops the music with null. Switching to the playing track does nothing.
  Future<void> music(String? track) async {
    if (!_enabled || track == _track) return;
    _track = track;
    _syncBackground();
    if (_web != null) return _web!.loop('music', track, _musicVolume);
    try {
      final player = _music ??= _newPlayer();
      await player.stop();
      if (track == null) return;
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(_musicVolume);
      await player.setSource(AssetSource('audio/$track.ogg'));
      if (!_quiet) await player.resume();
    } on Object catch (e) {
      debugPrint('music $track unavailable: $e');
    }
  }

  void play(SfxId id, {double volume = 1}) => _play(id.file, volume);

  /// The Hammer Strike: a whoosh as the hammer swings, and the clang as it
  /// lands, [landsIn] from now.
  void hammerStrike(Duration landsIn) {
    Future.delayed(landsIn - const Duration(milliseconds: 230), () => play(SfxId.swing, volume: 0.8));
    Future.delayed(landsIn - const Duration(milliseconds: 10), () => play(SfxId.hintHammer));
  }

  /// Tile-touch tink for the [n]th letter of the current word (1-based);
  /// the pitch rises with each tile.
  void tink(int n) => _play('tink_${n.clamp(1, tinkCount)}', 0.8);

  void _play(String file, double volume) {
    if (!_enabled || _quiet || _settings.sfxVolume <= 0) return;
    if (_web != null) return _web!.play(file, volume * _settings.sfxVolume);
    _voices[file]?.play(volume * _settings.sfxVolume).catchError((Object e) {
      debugPrint('sound $file failed: $e');
    });
  }

  Future<void> startAmbience() async {
    if (_web != null && !_webAmbience) {
      _webAmbience = true;
      return _web!.loop('ambience', 'forge_ambience', _ambienceVolume);
    }
    if (!_enabled || _ambience != null || _web != null) return;
    try {
      final player = _newPlayer();
      _ambience = player;
      _syncBackground();
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(_ambienceVolume);
      await player.setSource(AssetSource('audio/forge_ambience.ogg'));
      if (!_quiet) await player.resume();
    } on Object catch (e) {
      debugPrint('ambience unavailable: $e');
    }
  }

  /// Follows the app on and off screen. Off screen, the music and ambience
  /// carry on if the player keeps playing in the background (MainActivity
  /// keeps them going, and makes way for calls and other apps' audio), and
  /// otherwise pause until it's back. [AppLifecycleState.detached] stops
  /// them for good.
  Future<void> lifecycle(AppLifecycleState state) async {
    if (!_enabled) return;
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        if (_offScreen) return;
        _offScreen = true;
        // A browser tab that's hidden goes quiet; iOS suspends it anyway.
        if (!_settings.backgroundAudio || kIsWeb) await _setQuiet(away: true);
      case AppLifecycleState.resumed:
        if (!_offScreen) return;
        _offScreen = false;
        await _setQuiet(away: false, interrupted: false);
      case AppLifecycleState.detached:
        await shutDown();
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// Tells Android whether there's music or ambience to keep going off
  /// screen; nothing to hear needs no service or audio focus.
  void _syncBackground() {
    final audible =
        (_track != null && _settings.musicVolume > 0) || (_ambience != null && _settings.ambienceVolume > 0);
    final on = _enabled && _settings.backgroundAudio && !_away && audible;
    if (on == _keepPlaying) return;
    _keepPlaying = on;
    _background.keepPlaying(on);
  }

  // A call or another app took over the audio while off screen, or gave it back.
  void _onInterruption(bool on) {
    if (on && !_offScreen) return;
    _setQuiet(interrupted: on);
  }

  /// Pauses or resumes the music and ambience as [_away] and [_interrupted]
  /// change.
  Future<void> _setQuiet({bool? away, bool? interrupted}) async {
    final was = _quiet;
    _away = away ?? _away;
    _interrupted = interrupted ?? _interrupted;
    if (_quiet == was) return;
    if (_web != null) return _web!.setQuiet(_quiet);
    try {
      if (_quiet) {
        await _music?.pause();
        await _ambience?.pause();
      } else {
        if (_track != null) await _music?.resume();
        await _ambience?.resume();
      }
    } on Object catch (e) {
      debugPrint('audio ${_quiet ? 'pause' : 'resume'}: $e');
    }
  }

  /// The app is closing: stop everything for good.
  Future<void> shutDown() async {
    _away = true;
    _syncBackground();
    await _web?.close();
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
