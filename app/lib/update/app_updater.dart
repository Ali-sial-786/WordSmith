import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Why an update didn't download, by AppUpdater.kt's error code.
class UpdateFailure implements Exception {
  const UpdateFailure(this.code);

  final String code;

  String get message => switch (code) {
    'missing' => 'The new version is still on its way. Try again in a few minutes.',
    'space' => 'Not enough free space for the update. Clear some room and try again.',
    'invalid' => "That download wasn't the right file. Try again later.",
    'cancelled' => 'Download cancelled.',
    _ => "Couldn't download the update. Check your connection and try again.",
  };
}

/// Updates the Android app from inside it, through MainActivity's
/// `wordsmith/update` channel: downloads the new version's APK, then opens
/// Android's installer on it. Android asks the player, once, to let the game
/// install apps ("unknown sources").
class AppUpdater {
  const AppUpdater();

  static const _channel = MethodChannel('wordsmith/update');

  /// Only the Android app updates itself (the browser version reloads).
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Downloads [version]'s APK from [url], reporting bytes as they come
  /// ([total] is -1 when the server doesn't say), and returns its path.
  /// Throws [UpdateFailure].
  Future<String> download(String url, String version, {void Function(int received, int total)? onProgress}) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'progress') return;
      final m = call.arguments as Map<Object?, Object?>;
      onProgress?.call((m['received'] as num).toInt(), (m['total'] as num).toInt());
    });
    try {
      final path = await _channel.invokeMethod<String>('download', {'url': url, 'version': version});
      if (path == null) throw const UpdateFailure('network');
      return path;
    } on PlatformException catch (e) {
      throw UpdateFailure(e.code);
    } on MissingPluginException {
      throw const UpdateFailure('unsupported');
    } finally {
      _channel.setMethodCallHandler(null);
    }
  }

  Future<void> cancel() => _channel.invokeMethod<void>('cancel');

  /// Whether the player has let the game install apps.
  Future<bool> canInstall() async => await _channel.invokeMethod<bool>('canInstall') ?? false;

  /// Opens the game's "Install unknown apps" switch in Android's settings.
  Future<void> allowInstalls() => _channel.invokeMethod<void>('allowInstalls');

  /// Opens Android's installer on the APK at [path]; false if it couldn't.
  Future<bool> install(String path) async => await _channel.invokeMethod<bool>('install', path) ?? false;
}

final appUpdaterProvider = Provider<AppUpdater>((_) => const AppUpdater());
