import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../game/party.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../video/video_call.dart';
import 'coop_entry.dart';

/// Asks before leaving a room for good. [midSeries]: a Versus series is on.
Future<bool> showLeaveRoomDialog(BuildContext context, {bool midSeries = false}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave the forge?'),
        content: Text(
          midSeries
              ? "You're mid-series. If you're not back within 30 seconds, you can't win any more rounds."
              : 'You can rejoin with the code while the room is open.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Stay')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Leave')),
        ],
      ),
    ) ??
    false;

/// Around every screen: while the player is in a room but looking elsewhere,
/// a bar at the top leads back to it, with voice chat and Leave. A round
/// starting brings everyone back; the party's notices show wherever they are.
class PartyHost extends ConsumerStatefulWidget {
  const PartyHost({super.key, required this.router, required this.child});

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<PartyHost> createState() => _PartyHostState();
}

class _PartyHostState extends ConsumerState<PartyHost> {
  late final Party _party;
  late final StreamSubscription<RoomEvent> _effects;
  late final StreamSubscription<String> _notices;
  bool _wasActive = false;

  @override
  void initState() {
    super.initState();
    _party = ref.read(partyProvider)..addListener(_changed);
    _effects = _party.effects.listen(_onEffect);
    _notices = _party.notices.listen(_snack);
    widget.router.routerDelegate.addListener(_changed);
  }

  @override
  void dispose() {
    _party.removeListener(_changed);
    widget.router.routerDelegate.removeListener(_changed);
    _effects.cancel();
    _notices.cancel();
    // The app itself is going: let go of the room (its seat is held a while).
    _party.clear();
    super.dispose();
  }

  /// The top screen's path (a pushed one's too, unlike the configuration's uri).
  String get _path => widget.router.routerDelegate.currentConfiguration.isEmpty ? '' : widget.router.state.uri.path;

  bool get _inRoom => _path.startsWith('/room/');

  void _snack(String message) {
    if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  void _changed() {
    if (!mounted) return;
    final active = _party.active;
    // The room closed while the player was elsewhere: say so, and forget it.
    if (_wasActive && !active && _party.session != null && !_inRoom) {
      _snack('Your forge has closed.');
      WidgetsBinding.instance.addPostFrameCallback((_) => _party.clear());
    }
    _wasActive = active;
    // The router tells us of a new route while it builds.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _onEffect(RoomEvent e) {
    // The host started a round: everyone back to the room.
    if (e is RoundStart && _party.active && !_inRoom) _open();
  }

  void _open() => widget.router.push(_party.location);

  Future<void> _leave() async {
    final navigator = widget.router.routerDelegate.navigatorKey.currentContext;
    if (navigator == null || !await showLeaveRoomDialog(navigator)) return;
    await _party.leave();
  }

  @override
  Widget build(BuildContext context) {
    final lobby = _party.session?.lobby;
    final show = _party.active && lobby != null && !_inRoom;
    final media = MediaQuery.of(context);
    // The same tree either way, so the screens below keep their state.
    return Column(
      children: [
        if (show) _PartyBar(party: _party, lobby: lobby, onOpen: _open, onLeave: _leave) else const SizedBox.shrink(),
        Expanded(
          child: MediaQuery(data: show ? media.removePadding(removeTop: true) : media, child: widget.child),
        ),
      ],
    );
  }
}

class _PartyBar extends StatelessWidget {
  const _PartyBar({required this.party, required this.lobby, required this.onOpen, required this.onLeave});

  final Party party;
  final RoomLobby lobby;
  final VoidCallback onOpen;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final call = party.video;
    final playing = lobby.phase != 'lobby' && lobby.phase != 'results';
    return Material(
      key: const ValueKey('party-bar'),
      color: Palette.soot,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Palette.molten.withValues(alpha: 0.5))),
        ),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: onOpen,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Row(
                        children: [
                          Icon(Icons.groups, color: Palette.molten, size: 22),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${modeName(lobby.mode)} · ${lobby.code}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.titleSmall?.copyWith(color: Palette.whiteHeat),
                                ),
                                Text(
                                  playing
                                      ? 'Game on · tap to go back'
                                      : '${lobby.players.length} ${lobby.players.length == 1 ? 'smith' : 'smiths'} · '
                                            'tap to go back',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.labelSmall?.copyWith(color: Palette.steel),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (party.videoAvailable) ...[
                  if (call == null)
                    IconButton(
                      key: const ValueKey('party-voice'),
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.headset_mic_outlined, color: Palette.steel),
                      onPressed: party.enableVideo,
                    )
                  else ...[
                    IconButton(
                      key: const ValueKey('party-camera'),
                      visualDensity: VisualDensity.compact,
                      onPressed: call.status == VideoStatus.live ? party.toggleCamera : null,
                      icon: Icon(
                        call.cameraOn ? Icons.videocam : Icons.videocam_off,
                        color: call.cameraOn ? Palette.molten : Palette.steel,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('party-mic'),
                      visualDensity: VisualDensity.compact,
                      onPressed: call.status == VideoStatus.live ? party.toggleMic : null,
                      icon: Icon(
                        call.micOn ? Icons.mic : Icons.mic_off,
                        color: call.micOn ? Palette.molten : Palette.steel,
                      ),
                    ),
                  ],
                ],
                TextButton(
                  key: const ValueKey('party-leave'),
                  onPressed: onLeave,
                  child: Text('Leave', style: TextStyle(color: Palette.quenchRed)),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
