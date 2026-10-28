import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/heat.dart';
import '../../game/account.dart';
import '../../game/names.dart';
import '../../game/vs_session.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/video_bubble.dart';
import '../../video/video_call.dart';
import '../safety/player_actions.dart';
import '../vs/team_widgets.dart';
import '../vs/vs_widgets.dart';
import 'coop_entry.dart';
import 'room_chat.dart';
import 'room_video.dart';
import '../../ui/widgets/forge_frame.dart';

/// Before a round (co-op or Versus): the code to share, who's in, ready
/// checks, the heat, the series length in Versus, the teams and how a round
/// is won in Team Versus, and the host's start.
class LobbyView extends ConsumerWidget {
  const LobbyView({super.key, required this.session, required this.onLeave, this.video = RoomVideo.none});

  final RoomSession session;
  final VoidCallback onLeave;
  final RoomVideo video;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lobby = session.lobby!;
    final text = Theme.of(context).textTheme;
    final host = lobby.player(lobby.hostId);
    final hostName = host == null ? null : session.nameOf(host.id);
    final me = session.myPlayer;
    final vs = lobby.isVs;
    final team = lobby.isTeam && session is VsSession;
    final max = lobby.maxPlayers;
    final connected = lobby.players.where((p) => p.connected).length;
    final canStart = !vs || (connected >= 2 && (!team || lobby.teamsEven));
    Widget row(RoomPlayer p) => _PlayerRow(
      player: p,
      name: session.nameOf(p.id),
      isHost: p.id == lobby.hostId,
      isMe: p.id == session.me,
      call: video.call,
      blocked: ref.watch(accountProvider.select((a) => a.blocked.any((b) => b.id == p.id))),
      onMore: p.id == session.me
          ? null
          : () => showPlayerActions(
              context,
              ref,
              userId: p.id,
              name: session.nameOf(p.id),
              avatar: p.avatar,
              session: session,
            ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        ChatTitle(
          session: session,
          child: Text(
            team
                ? 'Team Clash'
                : vs
                ? 'Anvil Clash'
                : 'The Guild Forge',
            textAlign: TextAlign.center,
            style: displayStyle(24, color: Palette.molten),
          ),
        ),
        const SizedBox(height: 14),
        _CodeCard(code: lobby.code),
        const SizedBox(height: 12),
        if (session.isHost)
          HeatPicker(session: session)
        else
          HeatBanner(lobby: lobby, me: me, hostName: session.nameOf(lobby.hostId)),
        const SizedBox(height: 12),
        // Teams race classic rounds only.
        if (team)
          RulePicker(session: session as VsSession)
        else
          _VariantPicker(session: session, survival: lobby.survival, vs: vs),
        if (vs && session is VsSession) ...[
          const SizedBox(height: 12),
          _SeriesPicker(session: session as VsSession, series: lobby.series, total: lobby.totalScore),
          // Teams are won on round wins.
          if (!team) ...[
            const SizedBox(height: 12),
            _ScoringPicker(session: session as VsSession, total: lobby.totalScore),
          ],
        ],
        const SizedBox(height: 18),
        Text('Smiths ${lobby.players.length}/$max', style: text.titleMedium),
        const SizedBox(height: 6),
        if (team)
          TeamPicker(session: session as VsSession, row: row)
        else ...[
          for (final p in lobby.players) row(p),
          for (var i = lobby.players.length; i < max; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text('Waiting for a smith…', style: text.bodySmall),
            ),
        ],
        const SizedBox(height: 12),
        VideoBar(video: video),
        const SizedBox(height: 12),
        if (me != null)
          PlateButton(
            label: me.ready ? 'Ready!' : "I'm ready",
            icon: 'flame',
            onPressed: () => session.setReady(!me.ready),
          ),
        const SizedBox(height: 10),
        if (session.isHost)
          PlateButton(
            label: vs ? 'Start the series' : 'Start the round',
            sublabel: !canStart
                ? connected < 2
                      ? '${team ? 'Team Versus' : 'Versus'} needs at least 2 smiths'
                      : 'Teams must be the same size'
                : lobby.players.every((p) => p.ready || p.id == session.me)
                ? 'Everyone is ready'
                : 'Not everyone is ready yet',
            icon: vs ? 'trophy' : 'anvil',
            primary: true,
            onPressed: canStart ? session.startRound : null,
          )
        else
          Text(
            'Waiting for ${hostName ?? 'the host'} to start…',
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
                  // Any number of friends: it scrolls, and drags up to most of the screen.
                  isScrollControlled: true,
                  useSafeArea: true,
                  backgroundColor: Palette.soot,
                  builder: (_) =>
                      _InviteSheet(code: lobby.code, mode: lobby.mode, inRoom: {for (final p in lobby.players) p.id}),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(onPressed: onLeave, child: const Text('Leave')),
            ),
          ],
        ),
        // The room stays; the host can take it to another mode.
        if (session.isHost) ...[
          const SizedBox(height: 18),
          Text(
            'Play another mode, everyone staying',
            textAlign: TextAlign.center,
            style: text.labelMedium?.copyWith(color: Palette.steel),
          ),
          const SizedBox(height: 6),
          _ModePicker(session: session, mode: lobby.mode),
        ],
      ],
    );
  }
}

/// Who set the room's heat and what it pays [me]: "Auto · from host Ada's
/// level · ×1.6 XP for you", after the heat's name if [named].
/// [hostName] is how this player knows the host (a nickname, if they gave one).
String _heatCaption(RoomLobby lobby, RoomPlayer? me, {bool named = false, String? hostName}) {
  final heat = Heat.fromValue(lobby.heat.clamp(1, 6));
  final host = lobby.player(lobby.hostId);
  final name = hostName ?? host?.username;
  final mine = host != null && host.id == me?.id;
  final how = !lobby.autoHeatOn
      ? 'Picked by ${mine
            ? 'you'
            : host == null
            ? 'the host'
            : 'host $name'}'
      : lobby.isVs
      ? 'Auto · from the middle level in the room'
      : "Auto · from ${mine
            ? 'your'
            : host == null
            ? "the host's"
            : "host $name's"} level";
  final xp = me == null ? 1.0 : heat.xpMultiplierFor(me.level);
  return [if (named) heat.label, how, if (xp > 1) '×${xp.toStringAsFixed(1)} XP for you'].join(' · ');
}

/// The room's heat as everyone but the host sees it: the tier, in its
/// colour, who set it (the host, or Auto from levels), and its XP for me.
class HeatBanner extends StatelessWidget {
  const HeatBanner({super.key, required this.lobby, required this.me, this.hostName});

  final RoomLobby lobby;
  final RoomPlayer? me;
  final String? hostName;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final heat = Heat.fromValue(lobby.heat.clamp(1, 6));
    return Container(
      key: const ValueKey('heat-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Palette.heat(heat).withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Palette.heat(heat)),
      ),
      child: Column(
        children: [
          Text(heat.label, textAlign: TextAlign.center, style: text.titleSmall),
          Text(
            _heatCaption(lobby, me, hostName: hostName),
            textAlign: TextAlign.center,
            style: text.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// The host's pick of heat, for the next START or AGAIN: Auto (in the
/// colour of the tier it gives now) or Ember to White Heat, each named in
/// its own colour, with the banner's line under them.
class HeatPicker extends StatelessWidget {
  const HeatPicker({super.key, required this.session});

  final RoomSession session;

  @override
  Widget build(BuildContext context) {
    final lobby = session.lobby!;
    final auto = Heat.fromValue(lobby.autoHeat.clamp(1, 6));
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              flex: 2,
              child: _HeatTile(
                key: const ValueKey('heat-auto'),
                heat: auto,
                lines: ['Auto', auto.title],
                semantics: 'Auto heat, ${auto.title} now',
                selected: lobby.autoHeatOn,
                onTap: () => session.setHeat(null),
              ),
            ),
            for (final h in Heat.values) ...[
              const SizedBox(width: 4),
              Expanded(
                child: _HeatTile(
                  key: ValueKey('heat-${h.value}'),
                  heat: h,
                  lines: h.title.split(' '),
                  semantics: h.label,
                  selected: lobby.chosenHeat == h.value,
                  onTap: () => session.setHeat(h.value),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _heatCaption(lobby, session.myPlayer, named: true),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// One heat: a swatch of its colour with its name on it, ticked when picked.
class _HeatTile extends StatelessWidget {
  const _HeatTile({
    super.key,
    required this.heat,
    required this.lines,
    required this.semantics,
    required this.selected,
    required this.onTap,
  });

  final Heat heat;
  final List<String> lines;
  final String semantics;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Palette.heat(heat);
    final ink = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Palette.whiteHeat : Palette.darkLetter;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10, height: 1.1, color: ink);
    return Semantics(
      button: true,
      selected: selected,
      label: semantics,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: [
            Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: selected ? Palette.molten : Palette.ash, width: selected ? 3 : 1),
                boxShadow: selected ? [BoxShadow(color: Palette.ember.withValues(alpha: 0.7), blurRadius: 10)] : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final line in lines)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(line, maxLines: 1, style: style),
                    ),
                ],
              ),
            ),
            if (selected)
              Positioned(
                top: -6,
                right: -5,
                child: Container(
                  width: 15,
                  height: 15,
                  decoration: BoxDecoration(color: Palette.molten, shape: BoxShape.circle),
                  child: Icon(Icons.check, size: 11, color: Palette.forgeBlack),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Classic or Survival (shared/survival.md). The host picks; everyone sees it.
/// The host's pick of the room's mode: everyone stays, back in the lobby.
class _ModePicker extends StatelessWidget {
  const _ModePicker({required this.session, required this.mode});

  final RoomSession session;
  final String mode;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    spacing: 8,
    children: [
      for (final id in const ['coop', 'vs', 'team'])
        ChoiceChip(
          key: ValueKey('mode-$id'),
          label: Text(modeName(id)),
          selected: mode == id,
          selectedColor: Palette.ember.withValues(alpha: 0.35),
          labelStyle: TextStyle(color: Palette.whiteHeat),
          checkmarkColor: Palette.whiteHeat,
          side: BorderSide(color: mode == id ? Palette.molten : Palette.ash),
          onSelected: mode == id ? null : (_) => session.setMode(id),
        ),
    ],
  );
}

class _VariantPicker extends StatelessWidget {
  const _VariantPicker({required this.session, required this.survival, required this.vs});

  final RoomSession session;
  final bool survival;
  final bool vs;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            for (final (id, label) in const [('classic', 'Classic'), ('survival', 'Survival')])
              ChoiceChip(
                avatar: id == 'survival' ? const Icon(Icons.local_fire_department, size: 18) : null,
                label: Text(label),
                selected: survival == (id == 'survival'),
                selectedColor: Palette.ember.withValues(alpha: 0.35),
                // The text colour on the tint too: pale on a dark scheme's, dark on a light one's.
                labelStyle: TextStyle(color: Palette.whiteHeat),
                checkmarkColor: Palette.whiteHeat,
                side: BorderSide(color: survival == (id == 'survival') ? Palette.molten : Palette.ash),
                onSelected: session.isHost ? (_) => session.setVariant(id) : null,
              ),
          ],
        ),
        if (survival)
          Text(
            vs
                ? 'First heated word to melt ends the round; its smith loses it'
                : 'Forge each heated word before it melts',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: Palette.molten),
          ),
      ],
    );
  }
}

/// Versus: best of 3, 5, 7 or 10 (a total score series plays them all).
/// The host picks; everyone sees it.
class _SeriesPicker extends StatelessWidget {
  const _SeriesPicker({required this.session, required this.series, required this.total});

  final VsSession session;
  final int series;
  final bool total;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(
          session.isHost
              ? total
                    ? 'How many rounds?'
                    : 'Best of how many rounds?'
              : total
              ? '$series rounds · the host picks'
              : 'Best of $series · the host picks',
          style: text.labelLarge?.copyWith(color: Palette.steel),
        ),
        const SizedBox(height: 6),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final n in const [3, 5, 7, 10])
              ChoiceChip(
                label: Text('$n'),
                selected: series == n,
                selectedColor: Palette.ember.withValues(alpha: 0.35),
                labelStyle: TextStyle(color: Palette.whiteHeat),
                checkmarkColor: Palette.whiteHeat,
                side: BorderSide(color: series == n ? Palette.molten : Palette.ash),
                onSelected: session.isHost ? (_) => session.config(n) : null,
              ),
          ],
        ),
      ],
    );
  }
}

/// Versus: how the series is won, on round wins or on the total score. The
/// host picks; everyone sees it, with what it means.
class _ScoringPicker extends StatelessWidget {
  const _ScoringPicker({required this.session, required this.total});

  final VsSession session;
  final bool total;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(
          session.isHost ? 'How is the series won?' : 'How the series is won · the host picks',
          style: text.labelLarge?.copyWith(color: Palette.steel),
        ),
        const SizedBox(height: 6),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            for (final (id, label) in const [('rounds', 'Round wins'), ('total', 'Total score')])
              ChoiceChip(
                key: ValueKey('scoring-$id'),
                label: Text(label),
                selected: total == (id == 'total'),
                selectedColor: Palette.ember.withValues(alpha: 0.35),
                labelStyle: TextStyle(color: Palette.whiteHeat),
                checkmarkColor: Palette.whiteHeat,
                side: BorderSide(color: total == (id == 'total') ? Palette.molten : Palette.ash),
                onSelected: session.isHost ? (_) => session.setScoring(id) : null,
              ),
          ],
        ),
        Text(
          scoringBlurb(total),
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: Palette.molten),
        ),
      ],
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) => ForgePanel(
    padding: const EdgeInsets.all(14),
    child: Column(
      children: [
        Text('Room code', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(code, style: letterStyle(36, color: Palette.molten).copyWith(letterSpacing: 8)),
              ),
            ),
            IconButton(
              tooltip: 'Copy code',
              icon: Icon(Icons.copy, color: Palette.steel),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('Copied $code. Send it to your friends!')));
              },
            ),
          ],
        ),
      ],
    ),
  );
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({
    required this.player,
    required this.name,
    required this.isHost,
    required this.isMe,
    this.call,
    this.blocked = false,
    this.onMore,
  });

  final RoomPlayer player;

  /// As I see them (my nickname for a friend).
  final String name;
  final bool isHost;
  final bool isMe;
  final VideoCall? call;

  /// I've blocked them: their chat and emotes are hidden.
  final bool blocked;

  /// Mute, block or report them (not shown for me).
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final color = Palette.player(player.color);
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
          VideoBubble(
            userId: player.id,
            avatar: player.avatar,
            size: 48,
            call: call,
            color: color,
            dimmed: !player.connected,
            me: isMe,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$name${isMe ? ' (you)' : ''}', style: Theme.of(context).textTheme.titleSmall),
                Text(
                  [
                    'Lv ${player.level}',
                    if (isHost) 'Host',
                    if (blocked) 'Blocked',
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
          if (onMore != null)
            IconButton(
              tooltip: 'Mute, block or report',
              visualDensity: VisualDensity.compact,
              onPressed: onMore,
              icon: Icon(Icons.more_vert, color: Palette.steel),
            ),
        ],
      ),
    );
  }
}

class _InviteSheet extends ConsumerWidget {
  const _InviteSheet({required this.code, required this.mode, required this.inRoom});

  final String code;
  final String mode;
  final Set<String> inRoom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final names = ref.watch(displayNamesProvider);
    bool isOnline(String id) => (account.presence[id] ?? 'offline') != 'offline';
    // Online friends first; offline ones can still get a notification.
    final friends = account.friends.friends.where((f) => !inRoom.contains(f.id)).toList()
      ..sort((a, b) => (isOnline(a.id) ? 0 : 1).compareTo(isOnline(b.id) ? 0 : 1));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        children: [
          Text('Invite friends', style: displayStyle(20)),
          const SizedBox(height: 8),
          if (friends.isEmpty)
            Text(
              'No friends to invite yet. Share the code $code instead.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          for (final f in friends)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: AvatarBadge(avatar: f.avatar, size: 40, presence: account.presence[f.id]),
              title: Text(names.of(f.id, f.username)),
              subtitle: Text(isOnline(f.id) ? presenceLabel(account.presence[f.id]) : 'Offline · gets a notification'),
              trailing: TextButton(
                onPressed: () {
                  ref.read(accountProvider.notifier).invite(f.id, code, mode);
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('Invited ${names.of(f.id, f.username)}')));
                },
                child: const Text('Invite'),
              ),
            ),
        ],
      ),
    );
  }
}
