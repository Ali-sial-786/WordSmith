import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/sfx.dart';
import '../../game/account.dart';
import '../../game/coop_session.dart';
import '../../game/vs_session.dart';
import '../../game/providers.dart';
import '../../net/api_client.dart';
import '../../net/room_client.dart';
import '../../ui/effects/sparks.dart';
import '../../ui/mold/mold_grid.dart';
import '../../ui/theme/palette.dart';
import '../../ui/widgets/forge_background.dart';
import '../../video/video_call.dart';
import '../vs/vs_results_view.dart';
import '../vs/vs_round_view.dart';
import '../vs/vs_standings_view.dart';
import 'emotes.dart';
import 'lobby_view.dart';
import 'results_view.dart';
import 'room_video.dart';
import 'round_view.dart';

/// One room, co-op or Versus, from lobby to results and back.
class RoomScreen extends ConsumerStatefulWidget {
  const RoomScreen({super.key, required this.code, this.mode = 'coop'});

  final String code;

  /// `coop` or `vs`, from whoever sent us here (entry sheet, invite, open room).
  final String mode;

  @override
  ConsumerState<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends ConsumerState<RoomScreen> {
  RoomSession? _session;
  final _cues = MoldCues();
  late final AccountController _account;
  late final Sfx _sfx;
  late final SettingsNotifier _settings;
  StreamSubscription<RoomEvent>? _sub;
  StreamSubscription<String>? _hubErrors;
  bool _left = false;

  /// The room's video chat, while it's on.
  VideoCall? _video;
  bool _videoStarting = false;

  /// Video starts by itself once per room (when the setting is on).
  bool _videoAutoTried = false;

  @override
  void initState() {
    super.initState();
    _account = ref.read(accountProvider.notifier);
    _sfx = ref.read(sfxProvider);
    _settings = ref.read(settingsProvider.notifier);
    _hubErrors = _account.hubErrors.listen((code) {
      if (code == 'friend_offline') _toast("That friend is offline and can't get a notification right now.");
    });
    _prepare();
  }

  /// No room client in this build (no online play).
  bool get _offlineBuild => ref.read(roomClientFactoryProvider) == null;

  /// Why we can't join (missing, full, mid-round, signed out), worded for players.
  String? _problem;

  /// Checks the room before joining, whichever way the player got here
  /// (code, friend, invite banner or notification): missing, full and
  /// mid-round rooms explain themselves instead of spinning, and the wrong
  /// mode reopens as the right one.
  Future<void> _prepare() async {
    final factory = ref.read(roomClientFactoryProvider);
    if (factory == null) return;
    if (!await _accountReady()) {
      if (mounted) setState(() => _problem = 'Sign in to join rooms with friends.');
      return;
    }
    try {
      final mode = await _account.checkRoom(widget.code);
      if (!mounted) return;
      if (mode != widget.mode) {
        _reopening = true;
        context.pushReplacement('/room/${widget.code}?mode=$mode');
        return;
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      // Offline: join anyway; the socket keeps trying while the seat is held.
      if (!e.offline) {
        setState(() => _problem = e.friendly);
        return;
      }
    }
    final me = ref.read(accountProvider).user?.uid ?? '';
    final client = factory(widget.code);
    setState(() {
      _session = (widget.mode == 'vs' ? VsSession(client: client, me: me) : CoopSession(client: client, me: me))
        ..nicknameOf = _account.nicknameOf
        ..addListener(_changed);
    });
    _sub = _session!.effects.listen(_onEffect);
    _session!.start();
    _account.setStatus('in_room:${widget.code}');
  }

  /// Waits (briefly) for the account, e.g. when a notification opened the
  /// app and sign-in is still being restored. False if signed out.
  Future<bool> _accountReady() async {
    bool settled(AccountState s) =>
        s.isReady || s.phase == AccountPhase.signedOut || s.phase == AccountPhase.unavailable;
    var state = ref.read(accountProvider);
    if (!settled(state)) {
      final done = Completer<void>();
      final sub = ref.listenManual(accountProvider, (_, next) {
        if (settled(next) && !done.isCompleted) done.complete();
      });
      await done.future.timeout(const Duration(seconds: 15), onTimeout: () {});
      sub.close();
      if (!mounted) return false;
      state = ref.read(accountProvider);
    }
    return state.isReady;
  }

  bool _reopening = false;

  void _changed() {
    if (!mounted) return;
    // Opened with the wrong mode (an old link)? Reopen as what the room is.
    final mode = _session?.lobby?.mode;
    if (mode != null && mode != widget.mode && !_reopening) {
      _reopening = true;
      _left = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.pushReplacement('/room/${widget.code}?mode=$mode');
      });
      return;
    }
    // No music in rooms: friends talk over voice chat, and the forge's
    // ambience and sounds carry the game. The hall music is back on leaving.
    ref.read(sfxProvider).music(null);
    // Video joins once the room has seated us.
    if (!_videoAutoTried && _session?.lobby != null && ref.read(settingsProvider).videoChat) {
      _videoAutoTried = true;
      _startVideo();
    }
    setState(() {});
  }

  // ---- Video chat ----

  bool get _videoAvailable => ref.read(videoCallFactoryProvider) != null && ref.read(apiClientProvider) != null;

  void _toast(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _startVideo() async {
    if (_video != null || _videoStarting || _left || !_videoAvailable) return;
    _videoStarting = true;
    try {
      final grant = await ref.read(apiClientProvider)!.roomVideo(widget.code);
      if (!mounted || _left) return;
      final call = ref.read(videoCallFactoryProvider)!(_session!.me)..addListener(_videoChanged);
      setState(() => _video = call);
      final s = ref.read(settingsProvider);
      await call.join(url: grant.url, token: grant.token, camera: s.videoCamera, mic: s.videoMic);
    } on ApiException catch (e) {
      // Turn the setting back off so we don't ask again on every update.
      if (e.code == 'video_unavailable') _settings.update((s) => s.copyWith(videoChat: false));
      _toast(e.friendly);
    } finally {
      _videoStarting = false;
    }
  }

  void _videoChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _stopVideo() async {
    final call = _video;
    if (call == null) return;
    setState(() => _video = null);
    call.removeListener(_videoChanged);
    await call.leave();
    call.dispose();
  }

  void _enableVideo() {
    _settings.update((s) => s.copyWith(videoChat: true));
    _startVideo();
  }

  void _disableVideo() {
    _settings.update((s) => s.copyWith(videoChat: false));
    _stopVideo();
  }

  Future<void> _toggleCamera() async {
    final call = _video;
    if (call == null) return;
    await call.setCamera(!call.cameraOn);
    _settings.update((s) => s.copyWith(videoCamera: call.cameraOn));
  }

  Future<void> _toggleMic() async {
    final call = _video;
    if (call == null) return;
    await call.setMic(!call.micOn);
    _settings.update((s) => s.copyWith(videoMic: call.micOn));
  }

  RoomVideo get _roomVideo => RoomVideo(
    available: _videoAvailable,
    call: _video,
    onEnable: _enableVideo,
    onDisable: _disableVideo,
    onCamera: _toggleCamera,
    onMic: _toggleMic,
  );

  void _onEffect(RoomEvent e) {
    final sfx = ref.read(sfxProvider);
    switch (e) {
      case RoundStart():
        _cues.clear();
      case RoundEnd(:final completed, :final melted, :final xp):
        // A melt has its own sound.
        if (completed) {
          sfx.play(SfxId.forged);
        } else if (!melted) {
          sfx.play(SfxId.roundLose, volume: 0.8);
        }
        if ((xp[_session?.me]?.levelUps ?? 0) > 0) {
          Future.delayed(const Duration(milliseconds: 900), () => sfx.play(SfxId.levelUp));
        }
        // XP, level and hints changed on the server: refresh the profile.
        _account.sync();
      case VsRoundEnd(:final winner, :final melted):
        // After the melt, if there was one.
        Future.delayed(melted == null ? Duration.zero : meltDuration, () {
          winner == _session?.me ? sfx.play(SfxId.roundWin) : sfx.play(SfxId.roundLose, volume: 0.8);
        });
      case SeriesEnd(:final winner, :final xp):
        // When the podium shows, after the last round's molds.
        final s = _session;
        final podium = s is VsSession ? s.finalRoundLeft : Duration.zero;
        Future.delayed(podium, () {
          winner == _session?.me ? sfx.play(SfxId.seriesWin) : sfx.play(SfxId.roundLose, volume: 0.8);
        });
        if ((xp[_session?.me]?.levelUps ?? 0) > 0) {
          Future.delayed(podium + const Duration(milliseconds: 1600), () => sfx.play(SfxId.levelUp));
        }
        _account.sync();
      case RoomError(:final code):
        final message = switch (code) {
          'no_puzzle' => 'The forge has no puzzles ready. Try again in a minute.',
          'not_host' => 'Only the host can do that.',
          'not_enough_players' => 'Waiting for a smith to connect.',
          _ => null,
        };
        if (message != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
        }
      case RoomEmote(:final from, :final emote):
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 2),
              content: Text('${_session?.nameOf(from)}: ${emoteText(emote)}'),
            ),
          );
        }
      default:
        break;
    }
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave the forge?'),
        content: Text(
          _session is VsSession && const {'countdown', 'round', 'standings'}.contains(_session?.phase)
              ? "You're mid-series. If you're not back within 30 seconds, you can't win any more rounds."
              : 'You can rejoin with the code while the room is open.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Stay')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Leave')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _left = true);
    // Leave the room first: tearing down video can take a few seconds.
    await _session?.leave();
    await _stopVideo();
    if (mounted) context.canPop() ? context.pop() : context.go('/');
  }

  @override
  void dispose() {
    _hubErrors?.cancel();
    final video = _video;
    if (video != null) {
      video.removeListener(_videoChanged);
      video.leave().whenComplete(video.dispose);
    }
    _sub?.cancel();
    final session = _session;
    if (session != null) {
      if (!_left) session.leave();
      session
        ..removeListener(_changed)
        ..dispose();
    }
    // Reopening as the other mode: the new screen has already set these.
    if (!_reopening) {
      if (session != null) _account.setStatus('online');
      _sfx.music('music_hall');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final reducedMotion = ref.watch(settingsProvider.select((s) => s.reducedMotion));
    return PopScope(
      // Nothing joined yet (checking, or a problem): back just goes back.
      canPop: session == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        body: ForgeBackground(
          image: 'assets/images/bg_hall.webp',
          fire: 0.8,
          fireHeight: 0.4,
          dim: 0.62,
          child: SparkField(
            intensity: reducedMotion ? 0.35 : 1,
            child: SafeArea(
              child: switch (session) {
                _ when _offlineBuild => _message('Online play is not set up in this build.'),
                _ when _problem != null => _message(_problem!, action: 'Back to the Forge Hall'),
                null => _message('Joining forge ${widget.code}…', busy: true),
                final s => _body(s),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(RoomSession s) {
    if (_left) return _message('Leaving the forge…', busy: true);
    if (s.connection == RoomConnection.closed) {
      return _message(
        s.closeCode == 4001 ? 'Your account was deleted.' : 'This forge has closed.',
        action: 'Back to the Forge Hall',
      );
    }
    if (s.lobby == null) return _message('Joining forge ${widget.code}…', busy: true);
    final view = switch (s) {
      CoopSession() => switch (s.phase) {
        // A melt plays out on the mold before the results.
        _ when s.melting && s.round != null && s.mold != null => RoundView(
          session: s,
          cues: _cues,
          onLeave: _leave,
          video: _roomVideo,
        ),
        'results' when s.results != null => ResultsView(session: s, cues: _cues, onLeave: _leave),
        'countdown' ||
        'round' when s.round != null => RoundView(session: s, cues: _cues, onLeave: _leave, video: _roomVideo),
        _ => LobbyView(session: s, onLeave: _leave, video: _roomVideo),
      },
      VsSession() => switch (s.phase) {
        // A melt plays out, and the round that decided the series stays up a moment, before the podium.
        _ when (s.melting || s.showingFinalRound) && s.round != null && s.mold != null => VsRoundView(
          session: s,
          cues: _cues,
          onLeave: _leave,
          video: _roomVideo,
        ),
        'results' when s.seriesEnd != null => VsResultsView(session: s, onLeave: _leave),
        'standings' || 'results' when s.standings != null => VsStandingsView(session: s, cues: _cues, onLeave: _leave),
        'countdown' ||
        'round' when s.round != null => VsRoundView(session: s, cues: _cues, onLeave: _leave, video: _roomVideo),
        _ => LobbyView(session: s, onLeave: _leave, video: _roomVideo),
      },
      _ => LobbyView(session: s, onLeave: _leave, video: _roomVideo),
    };
    return Stack(
      children: [
        Positioned.fill(child: view),
        if (s.connection == RoomConnection.reconnecting)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Palette.quenchRed.withValues(alpha: 0.85),
              padding: const EdgeInsets.all(6),
              child: const Text('Connection lost. Reconnecting…', textAlign: TextAlign.center),
            ),
          ),
      ],
    );
  }

  Widget _message(String text, {bool busy = false, String? action}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) CircularProgressIndicator(color: Palette.molten),
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          if (action != null) ...[
            const SizedBox(height: 16),
            TextButton(onPressed: () => context.go('/'), child: Text(action)),
          ],
        ],
      ),
    ),
  );
}
