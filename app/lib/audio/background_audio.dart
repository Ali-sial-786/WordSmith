import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The game's sound off screen, through MainActivity's `wordsmith/audio`
/// channel. When the game leaves the screen with its music playing on, it
/// runs a small foreground service (Android 17 silences background audio
/// without one) and holds duckable audio focus, so a phone call or another
/// app starting to play quietens it. On screen its sounds mix with the
/// player's own music and take no focus. Does nothing where there's no such
/// channel (tests, other platforms).
class BackgroundAudio {
  const BackgroundAudio();

  static const _channel = MethodChannel('wordsmith/audio');

  /// Whether the music and ambience should carry on once the game leaves
  /// the screen.
  Future<void> keepPlaying(bool on) async {
    try {
      await _channel.invokeMethod<void>('keepPlaying', on);
    } on MissingPluginException {
      return;
    } on PlatformException catch (e) {
      debugPrint('background audio: $e');
    }
  }

  /// [onChange] hears true when a call or another app takes over the audio
  /// off screen, and false when it's handed back.
  void listen(void Function(bool interrupted) onChange) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'interrupted') onChange(call.arguments == true);
    });
  }
}
