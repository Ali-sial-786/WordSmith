import 'dart:async';

import 'package:flutter/material.dart';

import '../../game/room_session.dart';
import '../../ui/theme/palette.dart';
import '../../ui/widgets/metal_button.dart';

/// Between rounds (shared/room-protocol.md, "Between rounds"): when the
/// next round starts, who's ready for it, and my button to be. Once
/// everyone in [players] who's connected is ready, it starts straight away.
class NextRoundBar extends StatefulWidget {
  const NextRoundBar({super.key, required this.session, required this.endsAt, required this.players});

  final RoomSession session;

  /// When the next round's countdown starts by itself, server ms.
  final int endsAt;

  /// Who'll play it: their readiness counts, and only they get the button.
  final List<String> players;

  @override
  State<NextRoundBar> createState() => _NextRoundBarState();
}

class _NextRoundBarState extends State<NextRoundBar> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final text = Theme.of(context).textTheme;
    final lobby = s.lobby;
    final secs = ((widget.endsAt - s.serverNow) / 1000).ceil().clamp(0, 99);
    final here = [
      for (final id in widget.players)
        if (lobby?.player(id) case final p? when p.connected) p,
    ];
    final ready = here.where((p) => p.ready).length;
    final playing = widget.players.contains(s.me);
    final iAmReady = s.myPlayer?.ready ?? false;
    return Column(
      key: const ValueKey('next-round-bar'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Next round in $secs', textAlign: TextAlign.center, style: text.titleMedium),
        if (here.length > 1)
          Text(
            '$ready of ${here.length} ready',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: Palette.steel),
          ),
        if (playing) ...[
          const SizedBox(height: 8),
          PlateButton(
            key: const ValueKey('ready-next'),
            label: iAmReady ? 'Ready!' : "I'm ready",
            sublabel: iAmReady
                ? here.length - ready <= 0
                      ? 'Starting…'
                      : 'Waiting for ${here.length - ready} more'
                : 'Starts as soon as everyone is ready',
            icon: 'flame',
            primary: !iAmReady,
            onPressed: iAmReady ? null : s.readyForNext,
          ),
        ],
      ],
    );
  }
}
