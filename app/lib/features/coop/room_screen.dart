import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/sfx.dart';
import '../../game/account.dart';
import '../../game/coop_session.dart';
import '../../game/providers.dart';
import '../../net/room_client.dart';
import '../../ui/effects/sparks.dart';
import '../../ui/mold/mold_grid.dart';
import '../../ui/theme/palette.dart';
import '../../ui/widgets/forge_background.dart';
import 'lobby_view.dart';
import 'results_view.dart';
import 'round_view.dart';

/// One co-op room, from lobby to results and back.
class RoomScreen extends ConsumerStatefulWidget {
  const RoomScreen({super.key, required this.code});

  final String code;

  @override
  ConsumerState<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends ConsumerState<RoomScreen> {
  CoopSession? _session;
  final _cues = MoldCues();
  late final AccountController _account;
  StreamSubscription<RoomEvent>? _sub;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    _account = ref.read(accountProvider.notifier);
    final factory = ref.read(roomClientFactoryProvider);
    final me = ref.read(accountProvider).user?.uid ?? '';
    if (factory != null) {
      _session = CoopSession(client: factory(widget.code), me: me)..addListener(_changed);
      _sub = _session!.effects.listen(_onEffect);
      _session!.start();
      _account.setStatus('in_room:${widget.code}');
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _onEffect(RoomEvent e) {
    final sfx = ref.read(sfxProvider);
    switch (e) {
      case RoundStart():
        _cues
          ..fillDelay.clear()
          ..flash.clear();
      case RoundEnd(:final completed):
        sfx.play(completed ? SfxId.forged : SfxId.tick);
        // XP, level and hints changed on the server: refresh the profile.
        _account.sync();
      case RoomEmote(:final from, :final emote):
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 2),
              content: Text('${_session?.nameOf(from)}: ${_emoteText(emote)}'),
            ),
          );
        }
      default:
        break;
    }
  }

  static String _emoteText(String id) => switch (id) {
    'nice' => 'Nice strike!',
    'close' => 'So close!',
    'fire' => '🔥',
    'hammer' => '🔨',
    'gg' => 'Good game!',
    _ => id,
  };

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave the forge?'),
        content: const Text('You can rejoin with the code while the room is open.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Stay')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Leave')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _left = true);
    await _session?.leave();
    if (mounted) context.canPop() ? context.pop() : context.go('/');
  }

  @override
  void dispose() {
    _sub?.cancel();
    final session = _session;
    if (session != null) {
      if (!_left) session.leave();
      session
        ..removeListener(_changed)
        ..dispose();
    }
    _account.setStatus('online');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final reducedMotion = ref.watch(settingsProvider.select((s) => s.reducedMotion));
    return PopScope(
      canPop: false,
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
            child: SafeArea(child: session == null ? _message('Online play is not set up in this build.') : _body(session)),
          ),
        ),
      ),
    );
  }

  Widget _body(CoopSession s) {
    if (_left) return _message('Leaving the forge…', busy: true);
    if (s.connection == RoomConnection.closed) {
      return _message(
        s.closeCode == 4001 ? 'Your account was deleted.' : 'This forge has closed.',
        action: 'Back to the Forge Hall',
      );
    }
    if (s.lobby == null) return _message('Joining forge ${widget.code}…', busy: true);
    final view = switch (s.phase) {
      'results' when s.results != null => ResultsView(session: s, cues: _cues, onLeave: _leave),
      'countdown' || 'round' when s.round != null => RoundView(session: s, cues: _cues, onLeave: _leave),
      _ => LobbyView(session: s, onLeave: _leave),
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
          if (busy) const CircularProgressIndicator(color: Palette.molten),
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
