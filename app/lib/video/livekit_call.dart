import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart';

import 'call_service.dart';
import 'video_call.dart';

/// Video chat through LiveKit Cloud. Small, low-frame-rate video (the bubbles
/// are avatar-sized), and each phone only downloads the size it shows.
class LiveKitCall extends VideoCall {
  LiveKitCall({required this.me, this.service = const CallService()});

  /// This player's user ID (their LiveKit identity).
  final String me;

  /// Keeps the call, and its mic, going while the app is in the background.
  final CallService service;

  Room? _room;
  EventsListener<RoomEvent>? _events;
  VideoStatus _status = VideoStatus.off;
  String? _error;
  bool _cameraOn = false;
  bool _micOn = false;
  bool _leaving = false;

  /// What the service was last told: null out of the call, else the mic.
  bool? _serviceMic;

  static const _options = RoomOptions(
    adaptiveStream: true,
    dynacast: true,
    defaultCameraCaptureOptions: CameraCaptureOptions(params: VideoParametersPresets.h180_43, maxFrameRate: 15),
    defaultVideoPublishOptions: VideoPublishOptions(simulcast: false),
  );

  @override
  VideoStatus get status => _status;
  @override
  String? get error => _error;
  @override
  bool get cameraOn => _cameraOn;
  @override
  bool get micOn => _micOn;

  void _set(VideoStatus status) {
    _status = status;
    notifyListeners();
  }

  /// Tells the service whether we're in the call and whether the mic is on,
  /// so friends keep hearing us (and we them) with the app in the
  /// background. It stays through a reconnect, since Android won't start it
  /// again off screen.
  void _syncService() {
    final inCall = _room != null && (_status == VideoStatus.live || _status == VideoStatus.reconnecting);
    final mic = inCall ? _micOn : null;
    if (mic == _serviceMic) return;
    _serviceMic = mic;
    unawaited(mic == null ? service.stop() : service.start(mic: mic));
  }

  @override
  void notifyListeners() {
    _syncService();
    super.notifyListeners();
  }

  @override
  Future<void> join({required String url, required String token, required bool camera, required bool mic}) async {
    if (_room != null) return;
    _leaving = false;
    _error = null;
    _set(VideoStatus.connecting);
    final room = Room(roomOptions: _options);
    _room = room;
    room.addListener(_changed);
    _events = room.createListener()..listen(_onEvent);
    try {
      await room.connect(url, token);
      if (_leaving) return;
      _set(VideoStatus.live);
      try {
        // Voices come out of the loudspeaker, like the game sounds.
        await AudioManager.instance.setSpeakerOutputPreferred(true);
      } on Object catch (e) {
        debugPrint('speakerphone: $e');
      }
      await setCamera(camera);
      await setMic(mic);
    } on Object catch (e) {
      debugPrint('video connect failed: $e');
      _error = "Video chat couldn't connect.";
      await _close();
      _set(VideoStatus.failed);
    }
  }

  void _changed() => notifyListeners();

  void _onEvent(RoomEvent e) {
    switch (e) {
      case RoomReconnectingEvent():
        _status = VideoStatus.reconnecting;
      case RoomReconnectedEvent():
        _status = VideoStatus.live;
      case RoomDisconnectedEvent():
        if (!_leaving) {
          _status = VideoStatus.failed;
          _error = 'Video chat disconnected.';
        }
      default:
        break;
    }
    // Participants, tracks, mutes and speakers all change what's shown.
    notifyListeners();
  }

  @override
  Future<void> setCamera(bool on) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    try {
      await local.setCameraEnabled(on);
      _cameraOn = on;
      _error = null;
    } on Object catch (e) {
      debugPrint('camera: $e');
      _cameraOn = false;
      _error = "Couldn't use the camera. Check the camera permission for Wordsmith.";
    }
    notifyListeners();
  }

  @override
  Future<void> setMic(bool on) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    try {
      await local.setMicrophoneEnabled(on);
      _micOn = on;
      _error = null;
    } on Object catch (e) {
      debugPrint('mic: $e');
      _micOn = false;
      _error = "Couldn't use the microphone. Check the microphone permission for Wordsmith.";
    }
    notifyListeners();
  }

  Iterable<Participant> get _participants sync* {
    final room = _room;
    if (room == null) return;
    final local = room.localParticipant;
    if (local != null) yield local;
    yield* room.remoteParticipants.values;
  }

  static VideoTrack? _camera(Participant p) {
    for (final pub in p.videoTrackPublications) {
      final track = pub.track;
      if (pub.source == TrackSource.camera && !pub.muted && track is VideoTrack) return track;
    }
    return null;
  }

  @override
  Map<String, VideoPeer> get peers => {
    for (final p in _participants)
      p.identity: VideoPeer(
        id: p.identity,
        camera: _camera(p) != null,
        mic: p.isMicrophoneEnabled(),
        speaking: p.isSpeaking,
      ),
  };

  @override
  Widget? view(String userId) {
    for (final p in _participants) {
      if (p.identity != userId) continue;
      final track = _camera(p);
      if (track == null) return null;
      return VideoTrackRenderer(
        track,
        key: ValueKey(track.sid ?? track.mediaStreamTrack.id),
        fit: VideoViewFit.cover,
        mirrorMode: p is LocalParticipant ? VideoViewMirrorMode.mirror : VideoViewMirrorMode.off,
      );
    }
    return null;
  }

  Future<void> _close() async {
    final room = _room;
    final events = _events;
    _room = null;
    _events = null;
    _cameraOn = false;
    _micOn = false;
    room?.removeListener(_changed);
    await events?.dispose();
    try {
      await room?.disconnect();
    } on Object catch (e) {
      debugPrint('video disconnect: $e');
    }
    await room?.dispose();
  }

  @override
  Future<void> leave() async {
    _leaving = true;
    await _close();
    _status = VideoStatus.off;
    notifyListeners();
  }

  @override
  void dispose() {
    _leaving = true;
    unawaited(_close());
    _syncService();
    super.dispose();
  }
}
