import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/heat.dart';
import '../../game/account.dart';
import '../../game/coop_session.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/metal_button.dart';

/// Before a round: the code to share, who's in, ready checks, host start.
class LobbyView extends ConsumerWidget {
  const LobbyView({super.key, required this.session, required this.onLeave});

  final CoopSession session;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lobby = session.lobby!;
    final text = Theme.of(context).textTheme;
    final heat = Heat.fromValue(lobby.heat.clamp(1, 6));
    final host = lobby.player(lobby.hostId);
    final me = session.myPlayer;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        Text('The Guild Forge', textAlign: TextAlign.center, style: displayStyle(24, color: Palette.molten)),
        const SizedBox(height: 14),
        _CodeCard(code: lobby.code),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Palette.heat(heat).withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Palette.heat(heat)),
          ),
          child: Text(
            '${heat.title} heat · set by host ${host?.username ?? '?'} (Lv ${host?.level ?? '?'})',
            textAlign: TextAlign.center,
            style: text.titleSmall,
          ),
        ),
        const SizedBox(height: 18),
        Text('Smiths ${lobby.players.length}/4', style: text.titleMedium),
        const SizedBox(height: 6),
        for (final p in lobby.players) _PlayerRow(player: p, isHost: p.id == lobby.hostId, isMe: p.id == session.me),
        for (var i = lobby.players.length; i < 4; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text('Waiting for a smith…', style: text.bodySmall),
          ),
        const SizedBox(height: 16),
        if (me != null)
          PlateButton(
            label: me.ready ? 'Ready!' : "I'm ready",
            icon: 'flame',
            onPressed: () => session.setReady(!me.ready),
          ),
        const SizedBox(height: 10),
        if (session.isHost)
          PlateButton(
            label: 'Start the round',
            sublabel: lobby.players.every((p) => p.ready || p.id == session.me)
                ? 'Everyone is ready'
                : "Not everyone is ready (you can start anyway)",
            icon: 'anvil',
            primary: true,
            onPressed: session.startRound,
          )
        else
          Text(
            'Waiting for ${host?.username ?? 'the host'} to start…',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: Palette.steel),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Invite friends'),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  backgroundColor: Palette.soot,
                  builder: (_) => _InviteSheet(code: lobby.code, inRoom: {for (final p in lobby.players) p.id}),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(onPressed: onLeave, child: const Text('Leave')),
            ),
          ],
        ),
      ],
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Palette.soot,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF8C6B47)),
    ),
    child: Column(
      children: [
        Text('Room code', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(code, style: letterStyle(36, color: Palette.molten).copyWith(letterSpacing: 8)),
            IconButton(
              tooltip: 'Copy code',
              icon: const Icon(Icons.copy, color: Palette.steel),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Copied $code. Send it to your friends!')),
                );
              },
            ),
          ],
        ),
      ],
    ),
  );
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({required this.player, required this.isHost, required this.isMe});

  final RoomPlayer player;
  final bool isHost;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final color = Palette.players[player.color % 4];
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Palette.soot,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: color, width: 5)),
      ),
      child: Row(
        children: [
          Opacity(
            opacity: player.connected ? 1 : 0.4,
            child: AvatarBadge(avatar: player.avatar, size: 40),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${player.username}${isMe ? ' (you)' : ''}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  [
                    'Lv ${player.level}',
                    if (isHost) 'Host',
                    if (!player.connected) 'Reconnecting…',
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Icon(
            player.ready ? Icons.check_circle : Icons.radio_button_unchecked,
            color: player.ready ? Palette.verdigris : Palette.iron,
          ),
        ],
      ),
    );
  }
}

class _InviteSheet extends ConsumerWidget {
  const _InviteSheet({required this.code, required this.inRoom});

  final String code;
  final Set<String> inRoom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final online = account.friends.friends
        .where((f) => (account.presence[f.id] ?? 'offline') != 'offline' && !inRoom.contains(f.id))
        .toList();
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Invite friends', style: displayStyle(20)),
          const SizedBox(height: 8),
          if (online.isEmpty)
            Text(
              'No friends online right now. Share the code $code instead.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          for (final f in online)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: AvatarBadge(avatar: f.avatar, size: 40, presence: account.presence[f.id]),
              title: Text(f.username),
              subtitle: Text(presenceLabel(account.presence[f.id])),
              trailing: TextButton(
                onPressed: () {
                  ref.read(accountProvider.notifier).invite(f.id, code, 'coop');
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Invited ${f.username}')),
                  );
                },
                child: const Text('Invite'),
              ),
            ),
        ],
      ),
    );
  }
}
