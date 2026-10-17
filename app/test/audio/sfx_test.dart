import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/audio/background_audio.dart';
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

/// MainActivity's side of the background audio, recorded.
class _FakeBackground extends Fake implements BackgroundAudio {
  final sent = <bool>[];
  void Function(bool interrupted)? _onChange;

  @override
  Future<void> keepPlaying(bool on) async => sent.add(on);
  @override
  void listen(void Function(bool interrupted) onChange) => _onChange = onChange;

  void interrupt(bool on) => _onChange!(on);
}

/// Sounds with the ambience and hall music playing, and their call logs
/// cleared.
Future<(Sfx, _FakePlayer, _FakePlayer, _FakeBackground)> _playing(Settings settings) async {
  final players = <_FakePlayer>[];
  final background = _FakeBackground();
  final sfx = Sfx(
    enabled: true,
    settings: settings,
    newPlayer: () {
      final p = _FakePlayer();
      players.add(p);
      return p;
    },
    background: background,
  );
  await sfx.startAmbience();
  await sfx.music('music_hall');
  final [ambience, music] = players;
  expect(ambience.calls, ['resume']);
  expect(music.calls, ['stop', 'resume']);
  ambience.calls.clear();
  music.calls.clear();
  return (sfx, ambience, music, background);
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

  test('with background play on, the music and ambience carry on off screen', () async {
    final (sfx, ambience, music, background) = await _playing(const Settings());
    expect(background.sent, [true], reason: 'Android is told to keep them going');

    await goOffScreen(sfx);
    expect(ambience.calls, isEmpty);
    expect(music.calls, isEmpty);

    await comeBack(sfx);
    expect(ambience.calls, isEmpty);
    expect(music.calls, isEmpty);
  });

  test('with it off, they pause off screen and pick up again when back', () async {
    final (sfx, ambience, music, background) = await _playing(const Settings(backgroundAudio: false));
    expect(background.sent, isEmpty);

    await goOffScreen(sfx);
    expect(ambience.calls, ['pause']);
    expect(music.calls, ['pause']);

    await comeBack(sfx);
    expect(ambience.calls, ['pause', 'resume']);
    expect(music.calls, ['pause', 'resume']);
  });

  test('closing stops them for good, whatever the setting', () async {
    for (final on in [true, false]) {
      final (sfx, ambience, music, background) = await _playing(Settings(backgroundAudio: on));
      await sfx.lifecycle(AppLifecycleState.detached);
      expect(ambience.calls, ['stop', 'release']);
      expect(music.calls, ['stop', 'release']);
      expect(background.sent, on ? [true, false] : isEmpty);
    }
  });

  test('off screen, a call or another app quietens them until it gives the audio back', () async {
    final (sfx, ambience, music, background) = await _playing(const Settings());
    background.interrupt(true);
    await pumpEventQueue();
    expect(ambience.calls, isEmpty, reason: 'on screen the game mixes with other audio');

    await goOffScreen(sfx);
    background.interrupt(true);
    await pumpEventQueue();
    expect(ambience.calls, ['pause']);
    expect(music.calls, ['pause']);

    background.interrupt(false);
    await pumpEventQueue();
    expect(ambience.calls, ['pause', 'resume']);
    expect(music.calls, ['pause', 'resume']);

    // Another app takes over for good: quiet until the game is back.
    background.interrupt(true);
    await pumpEventQueue();
    await comeBack(sfx);
    expect(ambience.calls, ['pause', 'resume', 'pause', 'resume']);
    expect(music.calls, ['pause', 'resume', 'pause', 'resume']);
  });

  test('Android hears about it only while there is music or ambience to keep', () async {
    final background = _FakeBackground();
    final sfx = Sfx(enabled: true, newPlayer: _FakePlayer.new, background: background);
    sfx.applySettings(const Settings());
    expect(background.sent, isEmpty, reason: 'nothing playing yet');

    await sfx.music('music_hall');
    expect(background.sent, [true]);
    sfx.applySettings(const Settings(musicVolume: 0));
    expect(background.sent, [true, false]);
    sfx.applySettings(const Settings(backgroundAudio: false));
    sfx.applySettings(const Settings());
    expect(background.sent, [true, false, true]);
    await sfx.music(null);
    expect(background.sent, [true, false, true, false]);
  });

  test('silent sounds ignore the app going on and off screen', () async {
    final sfx = Sfx.silent();
    await goOffScreen(sfx);
    await sfx.lifecycle(AppLifecycleState.detached);
  });

  test('without the Android side, background audio does nothing', () async {
    const audio = BackgroundAudio();
    await expectLater(audio.keepPlaying(true), completes);
    audio.listen((_) {});
  });

  test('the background play setting is saved, and on unless turned off', () {
    final off = Settings.fromJson(const Settings().copyWith(backgroundAudio: false).toJson());
    expect(off.backgroundAudio, isFalse);
    expect(Settings.fromJson(const {'sfx': 0.5}).backgroundAudio, isTrue);
  });
}
