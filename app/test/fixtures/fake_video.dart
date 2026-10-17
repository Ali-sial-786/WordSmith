import 'package:flutter/widgets.dart';
import 'package:wordsmith/video/video_call.dart';

/// Video chat without LiveKit: tests set [peers] and watch the calls.
class FakeVideoCall extends VideoCall {
  VideoStatus _status = VideoStatus.off;
  bool _camera = false;
  bool _mic = false;
  final joins = <({String url, String token, bool camera, bool mic})>[];
  Map<String, VideoPeer> _peers = {};
  bool left = false;

  @override
  String? error;

  @override
  VideoStatus get status => _status;
  @override
  bool get cameraOn => _camera;
  @override
  bool get micOn => _mic;
  @override
  Map<String, VideoPeer> get peers => _peers;

  set peers(Map<String, VideoPeer> value) {
    _peers = value;
    notifyListeners();
  }

  set status(VideoStatus value) {
    _status = value;
    notifyListeners();
  }

  @override
  Future<void> join({required String url, required String token, required bool camera, required bool mic}) async {
    joins.add((url: url, token: token, camera: camera, mic: mic));
    _status = VideoStatus.live;
    _camera = camera;
    _mic = mic;
    notifyListeners();
  }

  @override
  Future<void> setCamera(bool on) async {
    _camera = on;
    notifyListeners();
  }

  @override
  Future<void> setMic(bool on) async {
    _mic = on;
    notifyListeners();
  }

  @override
  Widget? view(String userId) =>
      (peers[userId]?.camera ?? false) ? ColoredBox(key: ValueKey('video-$userId'), color: const Color(0xFF00FF00)) : null;

  @override
  Future<void> leave() async {
    left = true;
    _status = VideoStatus.off;
    notifyListeners();
  }
}
