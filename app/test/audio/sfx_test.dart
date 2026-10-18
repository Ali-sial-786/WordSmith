import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/audio/sfx.dart';
import 'package:wordsmith/data/profile.dart';

/// A player that records what it was asked to do with playback.
class _FakePlayer extends Fake implements AudioPlayer {
  final calls = <String>[];

  @override
  Future<void> setReleaseMode(ReleaseMode releaseMode) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setSource(Source source) async {}
  @override
  Future<void> resume() async => calls.add('resume');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> release() async => calls.add('release');
}

/// Sounds with the ambience and hall music playing, and their call logs
/// cleared.
Future<(Sfx, _FakePlayer, _FakePlayer)> _playing(Settings settings) async {
  final players = <_FakePlayer>[];
  final sfx = Sfx(
    enabled: true,
    settings: settings,
    newPlayer: () {
      final p = _FakePlayer();
      players.add(p);
      return p;
    },
  );
  await sfx.startAmbience();
  await sfx.music('music_hall');
  final [ambience, music] = players;
  expect(ambience.calls, ['resume']);
  expect(music.calls, ['stop', 'resume']);
  ambience.calls.clear();
  music.calls.clear();
  return (sfx, ambience, music);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> goOffScreen(Sfx sfx) async {
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      await sfx.lifecycle(s);
    }
  }

  Future<void> comeBack(Sfx sfx) async {
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      await sfx.lifecycle(s);
    }
  }

  test('the music and ambience pause off screen and pick up again when back', () async {
    final (sfx, ambience, music) = await _playing(const Settings());

    await goOffScreen(sfx);
    expect(ambience.calls, ['pause']);
    expect(music.calls, ['pause']);

    await comeBack(sfx);
    expect(ambience.calls, ['pause', 'resume']);
    expect(music.calls, ['pause', 'resume']);
  });

  test('music started off screen waits until the game is back', () async {
    final (sfx, ambience, music) = await _playing(const Settings());
    await goOffScreen(sfx);
    await sfx.music('music_round');
    expect(music.calls, ['pause', 'stop'], reason: 'loaded, not played');

    await comeBack(sfx);
    expect(music.calls, ['pause', 'stop', 'resume']);
  });

  test('no music: nothing to resume when back', () async {
    final (sfx, ambience, music) = await _playing(const Settings());
    await sfx.music(null);
    await goOffScreen(sfx);
    await comeBack(sfx);
    expect(music.calls, ['stop', 'pause']);
    expect(ambience.calls, ['pause', 'resume']);
  });

  test('closing stops them for good', () async {
    final (sfx, ambience, music) = await _playing(const Settings());
    await sfx.lifecycle(AppLifecycleState.detached);
    expect(ambience.calls, ['stop', 'release']);
    expect(music.calls, ['stop', 'release']);
  });

  test('silent sounds ignore the app going on and off screen', () async {
    final sfx = Sfx.silent();
    await goOffScreen(sfx);
    await sfx.lifecycle(AppLifecycleState.detached);
  });

  test('settings saved by older versions still load', () {
    final s = Settings.fromJson(const {'sfx': 0.5, 'backgroundAudio': true});
    expect(s.sfxVolume, 0.5);
  });
}
