import 'package:flutter/widgets.dart';

enum VideoStatus { off, connecting, live, reconnecting, failed }

/// One person in a room's video chat, by Wordsmith user ID.
class VideoPeer {
  const VideoPeer({required this.id, this.camera = false, this.mic = false, this.speaking = false});

  final String id;

  /// Sending video right now (camera on and not paused).
  final bool camera;
  final bool mic;
  final bool speaking;
}

/// A room's video chat, behind an interface so tests can use a fake
/// (the real one is [LiveKitCall]). Screens listen to it for changes.
abstract class VideoCall extends ChangeNotifier {
  VideoStatus get status;

  /// A problem worded for players, e.g. a refused camera permission.
  String? get error;

  bool get cameraOn;
  bool get micOn;

  /// Everyone in the call, this player included.
  Map<String, VideoPeer> get peers;

  Future<void> join({required String url, required String token, required bool camera, required bool mic});
  Future<void> setCamera(bool on);
  Future<void> setMic(bool on);

  /// Live video of [userId], or null while their camera is off.
  Widget? view(String userId);

  Future<void> leave();
}
