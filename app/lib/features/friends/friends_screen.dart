import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../game/account.dart';
import '../../net/api_client.dart';
import '../../net/models.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';

class FriendsScreen extends ConsumerStatefulWidget {
  const FriendsScreen({super.key});

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

  void _toast(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

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

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Friends', style: displayStyle(22)),
          centerTitle: true,
          bottom: const TabBar(
            indicatorColor: Palette.molten,
            labelColor: Palette.molten,
            tabs: [Tab(text: 'Friends'), Tab(text: 'Leaderboard')],
          ),
        ),
        body: TabBarView(children: [_friendsTab(context), const _LeaderboardTab()]),
      ),
    );
  }

  Widget _friendsTab(BuildContext context) {
    final account = ref.watch(accountProvider);
    final n = ref.read(accountProvider.notifier);
    final f = account.friends;
    final text = Theme.of(context).textTheme;
    final sorted = [...f.friends]..sort((a, b) {
      final ao = (account.presence[a.id] ?? 'offline') == 'offline' ? 1 : 0;
      final bo = (account.presence[b.id] ?? 'offline') == 'offline' ? 1 : 0;
      return ao != bo ? ao - bo : a.username.toLowerCase().compareTo(b.username.toLowerCase());
    });
    return RefreshIndicator(
      onRefresh: n.refreshFriends,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Add a friend by smith name',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _adding ? null : _add,
                style: FilledButton.styleFrom(backgroundColor: Palette.ember),
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
                      icon: const Icon(Icons.check_circle, color: Palette.verdigris),
                      onPressed: () => _act(() => n.respondFriend(p.id, accept: true)),
                    ),
                    IconButton(
                      tooltip: 'Decline',
                      icon: const Icon(Icons.cancel, color: Palette.iron),
                      onPressed: () => _act(() => n.respondFriend(p.id, accept: false)),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 22),
          Text(
            'Friends · ${account.friendsOnline} online',
            style: text.titleMedium,
          ),
          if (sorted.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No friends yet. Add someone by their smith name above.',
                style: text.bodySmall,
              ),
            ),
          for (final p in sorted)
            _PlayerTile(
              player: p,
              presence: account.presence[p.id] ?? 'offline',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if ((account.presence[p.id] ?? '').startsWith('in_room:'))
                    TextButton(
                      onPressed: () => _join(account.presence[p.id]!.substring('in_room:'.length)),
                      child: const Text('Join'),
                    ),
                  PopupMenuButton<String>(
                    onSelected: (_) => _act(() => n.removeFriend(p.id)),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'remove', child: Text('Remove friend')),
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
                trailing: TextButton(
                  onPressed: () => _act(() => n.removeFriend(p.id)),
                  child: const Text('Cancel'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _PlayerTile extends StatelessWidget {
  const _PlayerTile({required this.player, this.presence, this.trailing});

  final PlayerSummary player;
  final String? presence;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: AvatarBadge(avatar: player.avatar, size: 44, presence: presence),
    title: Text(player.username),
    subtitle: Text(
      presence == null
          ? 'Lv ${player.level} · ${player.rank}'
          : '${presenceLabel(presence)} · Lv ${player.level}',
    ),
    trailing: trailing,
  );
}

class _LeaderboardTab extends ConsumerStatefulWidget {
  const _LeaderboardTab();

  @override
  ConsumerState<_LeaderboardTab> createState() => _LeaderboardTabState();
}

class _LeaderboardTabState extends ConsumerState<_LeaderboardTab> {
  late Future<List<LeaderboardEntry>> _entries =
      ref.read(accountProvider.notifier).leaderboard();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
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
            return ListView(
              padding: const EdgeInsets.all(24),
              children: [Text(e is ApiException ? e.friendly : '$e')],
            );
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
                            Text(e.player.username, style: text.titleSmall),
                            Text(
                              'Lv ${e.player.level} · ${e.player.rank}',
                              style: text.bodySmall,
                            ),
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
