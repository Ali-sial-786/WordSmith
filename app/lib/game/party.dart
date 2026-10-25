import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/api_client.dart';
import '../net/room_client.dart';
import '../video/video_call.dart';
import 'account.dart';
import 'coop_session.dart';
import 'history_records.dart';
import 'providers.dart';
import 'vs_session.dart';

/// The room this phone is in, kept while the player looks around the rest of
/// the app: the room screen shows it, the bar at the top of every other
/// screen leads back to it.
final partyProvider = Provider<Party>((ref) {
  final party = Party(ref);
  ref.onDispose(party.dispose);
  return party;
});

/// One room from joining to leaving (shared/room-protocol.md, Switching
/// mode): its session, which follows the host's mode, and its voice and
/// video chat. Listeners hear the session's changes too.
class Party extends ChangeNotifier {
  Party(this._ref);

  final Ref _ref;

  /// The room's code, while in one.
  String? code;
  RoomSession? session;

  /// The mode [session] was made for.
  String? _mode;

  /// Every session's events, across mode changes.
  Stream<RoomEvent> get effects => _effects.stream;
  final _effects = StreamController<RoomEvent>.broadcast();
  StreamSubscription<RoomEvent>? _sub;

  /// Things to tell the player wherever they are (a video error).
  Stream<String> get notices => _notices.stream;
  final _notices = StreamController<String>.broadcast();

  /// In a room that's still open.
  bool get active => session != null && session!.connection != RoomConnection.closed;

  /// Where the room screen is.
  String get location => '/room/$code?mode=${session?.lobby?.mode ?? _mode}';

  AccountController get _account => _ref.read(accountProvider.notifier);

  /// Joins [code] as [mode] (what the server said it is); another room is left first.
  void join(String code, String mode) {
    if (this.code == code && session != null && session!.connection != RoomConnection.closed) return;
    if (session != null) unawaited(leave());
    final factory = _ref.read(roomClientFactoryProvider);
    if (factory == null) return;
    this.code = code;
    final me = _ref.read(accountProvider).user?.uid ?? '';
    _attach(_make(mode, factory(code), me)..chatEnabled = _ref.read(settingsProvider).textChat);
    session!.start();
    _account.setStatus('in_room:$code');
    notifyListeners();
  }

  RoomSession _make(String mode, RoomClient client, String me) {
    _mode = mode;
    return (mode == 'coop' ? CoopSession(client: client, me: me) : VsSession(client: client, me: me))
      ..nicknameOf = _account.nicknameOf
      ..isBlocked = _account.isBlocked;
  }

  void _attach(RoomSession s) {
    session = s..addListener(_changed);
    _sub = s.effects.listen(_onEffect);
  }

  void _detachSession() {
    final s = session;
    if (s == null) return;
    _sub?.cancel();
    _sub = null;
    s.removeListener(_changed);
    session = null;
  }

  bool _videoAutoTried = false;
  bool _closed = false;

  void _changed() {
    var s = session;
    if (s == null) return;
    // The host picked another mode: a fresh session of that kind on the
    // same connection (an old link opened as the wrong one switches too).
    final mode = s.lobby?.mode;
    if (mode != null && mode != _mode) {
      final old = s;
      _detachSession();
      _attach(s = _make(mode, old.client, old.me)..adopt(old));
      // Not while it's notifying (this is its listener).
      scheduleMicrotask(old.dispose);
    }
    if (s.connection == RoomConnection.closed && !_closed) {
      _closed = true;
      unawaited(_stopVideo());
      _account.setStatus('online');
    }
    // Voice chat joins once the room has seated us.
    if (!_videoAutoTried && s.lobby != null && _ref.read(settingsProvider).videoChat) {
      _videoAutoTried = true;
      startVideo();
    }
    notifyListeners();
  }

  void _onEffect(RoomEvent e) {
    final s = session;
    switch (e) {
      case RoundEnd():
        // XP, level and hints changed on the server: refresh the profile.
        _account.sync();
        if (s is CoopSession) {
          final record = coopRecord(s, e, at: DateTime.now().millisecondsSinceEpoch);
          if (record != null) _ref.read(historyProvider.notifier).add(record);
        }
      case SeriesEnd():
        _account.sync();
        if (s is VsSession) {
          final record = vsRecord(s, e, at: DateTime.now().millisecondsSinceEpoch);
          if (record != null) _ref.read(historyProvider.notifier).add(record);
        }
      default:
        break;
    }
    _effects.add(e);
  }

  /// Leaves the room for good: the seat, the voice chat, all of it.
  Future<void> leave() async {
    final s = session;
    if (s == null) return;
    // Leave the room first: tearing down video can take a few seconds.
    final left = s.leave();
    final video = _stopVideo();
    clear();
    await left;
    await video;
  }

  /// Forgets the room (it closed, or was left).
  void clear() {
    final s = session;
    if (s == null) return;
    _detachSession();
    s.dispose();
    unawaited(_stopVideo());
    if (!_closed) _account.setStatus('online');
    code = null;
    _mode = null;
    _closed = false;
    _videoAutoTried = false;
    notifyListeners();
  }

  // ---- Voice and video chat ----

  /// The room's call, while it's on.
  VideoCall? video;
  bool _videoStarting = false;

  bool get videoAvailable => _ref.read(videoCallFactoryProvider) != null && _ref.read(apiClientProvider) != null;

  Future<void> startVideo() async {
    final code = this.code;
    if (video != null || _videoStarting || code == null || !active || !videoAvailable) return;
    _videoStarting = true;
    try {
      final grant = await _ref.read(apiClientProvider)!.roomVideo(code);
      if (this.code != code || !active) return;
      final call = _ref.read(videoCallFactoryProvider)!(session!.me)..addListener(notifyListeners);
      video = call;
      notifyListeners();
      final s = _ref.read(settingsProvider);
      // The camera starts off: video is each player's own choice, in the room.
      // Players under 18 also start muted, every room (shared/age.md).
      final minor = _ref.read(accountProvider).server?.minor ?? false;
      await call.join(url: grant.url, token: grant.token, camera: false, mic: s.videoMic && !minor);
    } on ApiException catch (e) {
      // Turn the setting back off so we don't ask again on every update.
      if (e.code == 'video_unavailable') {
        _ref.read(settingsProvider.notifier).update((s) => s.copyWith(videoChat: false));
      }
      _notices.add(e.friendly);
    } finally {
      _videoStarting = false;
    }
  }

  Future<void> _stopVideo() async {
    final call = video;
    if (call == null) return;
    video = null;
    call.removeListener(notifyListeners);
    if (!_disposed) notifyListeners();
    await call.leave();
    call.dispose();
  }

  void enableVideo() {
    _ref.read(settingsProvider.notifier).update((s) => s.copyWith(videoChat: true));
    startVideo();
  }

  void disableVideo() {
    _ref.read(settingsProvider.notifier).update((s) => s.copyWith(videoChat: false));
    _stopVideo();
  }

  Future<void> toggleCamera() async {
    final call = video;
    if (call != null) await call.setCamera(!call.cameraOn);
  }

  Future<void> toggleMic() async {
    final call = video;
    if (call == null) return;
    await call.setMic(!call.micOn);
    _ref.read(settingsProvider.notifier).update((s) => s.copyWith(videoMic: call.micOn));
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    final s = session;
    if (s != null) {
      _detachSession();
      if (!_closed) s.leave();
      s.dispose();
    }
    final call = video;
    video = null;
    if (call != null) {
      call.removeListener(notifyListeners);
      call.leave().whenComplete(call.dispose);
    }
    _effects.close();
    _notices.close();
    super.dispose();
  }
}
