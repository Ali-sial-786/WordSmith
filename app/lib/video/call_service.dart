import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps a room's voice chat going with the app in the background, through
/// MainActivity's `wordsmith/call` channel and its foreground service, shown
/// as an ongoing "Voice chat on" notification. Android 11+ cuts the mic off
/// for background apps without one, and only lets it start while the game is
/// on screen: a mic turned on off screen waits until the game is back.
/// Does nothing where there's no such channel (tests, other platforms).
class CallService {
  const CallService();

  static const _channel = MethodChannel('wordsmith/call');

  /// In the call, with the [mic] on or off.
  Future<void> start({required bool mic}) => _call('start', {'mic': mic});

  /// Out of the call.
  Future<void> stop() => _call('stop');

  Future<void> _call(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      return;
    } on PlatformException catch (e) {
      debugPrint('call service $method: $e');
    }
  }
}
