import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../game/account.dart';
import '../../game/names.dart';
import '../../net/api_client.dart';
import '../../net/models.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/gold_field.dart';
import '../safety/player_actions.dart';

class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key, this.leaderboard = false});

  /// Open on the Leaderboard tab.
  final bool leaderboard;

  @override
  ConsumerState<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends ConsumerState<FriendsScreen> {
  final _name = TextEditingController();
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(accountProvider.notifier).refreshFriends());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _toast(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _adding = true);
    try {
      final accepted = await ref.read(accountProvider.notifier).requestFriend(name);
      _name.clear();
      _toast(accepted ? 'You and $name are now friends!' : 'Request sent to $name.');
    } on ApiException catch (e) {
      _toast(e.friendly);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } on ApiException catch (e) {
      _toast(e.friendly);
    }
  }

  /// Joins the room a friend is in, if it has space and isn't mid-round.
  Future<void> _join(String code) => _act(() async {
    final mode = await ref.read(accountProvider.notifier).checkRoom(code);
    if (mounted) context.push('/room/$code?mode=$mode');
  });

  void _editNickname(PlayerSummary friend) => showDialog<void>(
    context: context,
    builder: (_) => NicknameDialog(friend: friend),
  );

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: widget.leaderboard ? 1 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Friends', style: displayStyle(22)),
          centerTitle: true,
          bottom: TabBar(
            indicatorColor: Palette.molten,
            labelColor: Palette.molten,
            tabs: [
              Tab(text: 'Friends'),
              Tab(text: 'Leaderboard'),
            ],
          ),
        ),
        body: TabBarView(children: [_friendsTab(context), const _LeaderboardTab()]),
      ),
    );
  }

  Widget _friendsTab(BuildContext context) {
    final account = ref.watch(accountProvider);
    final names = ref.watch(displayNamesProvider);
    final n = ref.read(accountProvider.notifier);
    final f = account.friends;
    final text = Theme.of(context).textTheme;
    final sorted = [...f.friends]
      ..sort((a, b) {
        final ao = (account.presence[a.id] ?? 'offline') == 'offline' ? 1 : 0;
        final bo = (account.presence[b.id] ?? 'offline') == 'offline' ? 1 : 0;
        return ao != bo
            ? ao - bo
            : names.of(a.id, a.username).toLowerCase().compareTo(names.of(b.id, b.username).toLowerCase());
      });
    return RefreshIndicator(
      onRefresh: n.refreshFriends,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Add a friend', style: text.titleMedium),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: GoldTextField(
                  key: const ValueKey('add-friend'),
                  controller: _name,
                  hint: "Friend's username",
                  icon: Icons.person_add_alt_1,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _adding ? null : _add,
                style: FilledButton.styleFrom(
                  backgroundColor: Palette.ember,
                  minimumSize: const Size(72, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Add'),
              ),
            ],
          ),
          if (f.incoming.isNotEmpty) ...[
            const SizedBox(height: 22),
            Text('Requests', style: text.titleMedium),
            for (final p in f.incoming)
              _PlayerTile(
                player: p,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Accept',
                      icon: Icon(Icons.check_circle, color: Palette.verdigris),
                      onPressed: () => _act(() => n.respondFriend(p.id, accept: true)),
                    ),
                    IconButton(
                      tooltip: 'Decline',
                      icon: Icon(Icons.cancel, color: Palette.iron),
                      onPressed: () => _act(() => n.respondFriend(p.id, accept: false)),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 22),
          Text('Friends · ${account.friendsOnline} online', style: text.titleMedium),
          if (sorted.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('No friends yet. Add someone by their smith name above.', style: text.bodySmall),
            ),
          for (final p in sorted)
            _PlayerTile(
              player: p,
              nickname: names.nicknameOf(p.id),
              presence: account.presence[p.id] ?? 'offline',
              onTap: () => _editNickname(p),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if ((account.presence[p.id] ?? '').startsWith('in_room:'))
                    TextButton(
                      onPressed: () => _join(account.presence[p.id]!.substring('in_room:'.length)),
                      child: const Text('Join'),
                    ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    onSelected: (choice) => switch (choice) {
                      'nickname' => _editNickname(p),
                      'clear' => _act(() => n.setNickname(p.id, null)),
                      'safety' => showPlayerActions(
                        context,
                        ref,
                        userId: p.id,
                        name: names.of(p.id, p.username),
                        avatar: p.avatar,
                      ),
                      _ => _act(() => n.removeFriend(p.id)),
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'nickname',
                        child: Text(names.nicknameOf(p.id) == null ? 'Give a nickname' : 'Change nickname'),
                      ),
                      if (names.nicknameOf(p.id) != null)
                        const PopupMenuItem(value: 'clear', child: Text('Clear nickname')),
                      const PopupMenuItem(value: 'remove', child: Text('Remove friend')),
                      const PopupMenuItem(value: 'safety', child: Text('Block or report')),
                    ],
                  ),
                ],
              ),
            ),
          if (f.outgoing.isNotEmpty) ...[
            const SizedBox(height: 22),
            Text('Waiting for them', style: text.titleMedium),
            for (final p in f.outgoing)
              _PlayerTile(
                player: p,
                trailing: TextButton(onPressed: () => _act(() => n.removeFriend(p.id)), child: const Text('Cancel')),
              ),
          ],
        ],
      ),
    );
  }
}

/// A player's name as I see it, with their real username small underneath
/// when I've given them a nickname.
class _ShownName extends StatelessWidget {
  const _ShownName({required this.username, this.nickname, this.style});

  final String username;
  final String? nickname;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(nickname ?? username, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
      if (nickname != null)
        Text(
          username,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Palette.gold.withValues(alpha: 0.8)),
        ),
    ],
  );
}

class _PlayerTile extends StatelessWidget {
  const _PlayerTile({required this.player, this.nickname, this.presence, this.trailing, this.onTap});

  final PlayerSummary player;
  final String? nickname;
  final String? presence;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    onTap: onTap,
    leading: AvatarBadge(avatar: player.avatar, size: 44, presence: presence),
    title: _ShownName(username: player.username, nickname: nickname),
    subtitle: Text(
      presence == null ? 'Lv ${player.level} · ${player.rank}' : '${presenceLabel(presence)} · Lv ${player.level}',
    ),
    trailing: trailing,
  );
}

/// Sets, changes or clears the nickname I give a friend. Only I see it; it
/// shows instead of their username wherever they appear to me.
class NicknameDialog extends ConsumerStatefulWidget {
  const NicknameDialog({super.key, required this.friend});

  final PlayerSummary friend;

  @override
  ConsumerState<NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends ConsumerState<NicknameDialog> {
  late final _nickname = TextEditingController(text: ref.read(displayNamesProvider).nicknameOf(widget.friend.id));
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _save(String? nickname) async {
    final trimmed = nickname?.trim();
    if (trimmed != null && trimmed.isEmpty) {
      setState(() => _error = 'Type a nickname, or clear it.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountProvider.notifier).setNickname(widget.friend.id, trimmed);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.friendly);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final current = ref.watch(displayNamesProvider).nicknameOf(widget.friend.id);
    return AlertDialog(
      title: Text('Nickname for ${widget.friend.username}', style: displayStyle(18)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Only you see it. It shows instead of their name in rooms, invites, gifts and leaderboards.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 14),
          GoldTextField(
            key: const ValueKey('nickname'),
            controller: _nickname,
            hint: 'Nickname',
            icon: Icons.badge_outlined,
            maxLength: 20,
            autofocus: true,
            error: _error,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (v) => _busy ? null : _save(v),
          ),
        ],
      ),
      actions: [
        if (current != null)
          TextButton(
            onPressed: _busy ? null : () => _save(null),
            child: Text('Clear', style: TextStyle(color: Palette.quenchRed)),
          ),
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(
          onPressed: _busy ? null : () => _save(_nickname.text),
          child: Text('Save', style: TextStyle(color: Palette.molten)),
        ),
      ],
    );
  }
}

class _LeaderboardTab extends ConsumerStatefulWidget {
  const _LeaderboardTab();

  @override
  ConsumerState<_LeaderboardTab> createState() => _LeaderboardTabState();
}

class _LeaderboardTabState extends ConsumerState<_LeaderboardTab> {
  late Future<List<LeaderboardEntry>> _entries = ref.read(accountProvider.notifier).leaderboard();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final names = ref.watch(displayNamesProvider);
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => _entries = ref.read(accountProvider.notifier).leaderboard());
        await _entries;
      },
      child: FutureBuilder(
        future: _entries,
        builder: (context, snap) {
          if (snap.hasError) {
            final e = snap.error;
            return ListView(padding: const EdgeInsets.all(24), children: [Text(e is ApiException ? e.friendly : '$e')]);
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final e in snap.data!)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: e.me ? Palette.ember.withValues(alpha: 0.15) : Palette.soot,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: e.me ? Palette.molten : Palette.ash),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 34,
                        child: Text('${e.place}', style: displayStyle(20, color: Palette.molten)),
                      ),
                      AvatarBadge(avatar: e.player.avatar, size: 40),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _ShownName(
                              username: e.player.username,
                              nickname: e.me ? null : names.nicknameOf(e.player.id),
                              style: text.titleSmall,
                            ),
                            Text('Lv ${e.player.level} · ${e.player.rank}', style: text.bodySmall),
                          ],
                        ),
                      ),
                      Text('${e.totalXp} XP', style: text.labelLarge),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
