import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/account.dart';
import '../../net/api_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';

/// Settings › Blocked smiths: everyone I've blocked, to unblock.
class BlockedScreen extends ConsumerStatefulWidget {
  const BlockedScreen({super.key});

  @override
  ConsumerState<BlockedScreen> createState() => _BlockedScreenState();
}

class _BlockedScreenState extends ConsumerState<BlockedScreen> {
  @override
  void initState() {
    super.initState();
    ref.read(accountProvider.notifier).refreshBlocks();
  }

  Future<void> _unblock(String id, String name) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(accountProvider.notifier).unblock(id);
      messenger.showSnackBar(SnackBar(content: Text('Unblocked $name.')));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.friendly)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = ref.watch(accountProvider.select((a) => a.blocked));
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text('Blocked smiths', style: displayStyle(22)), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            "Blocked smiths' messages and emotes are hidden in every room, and they can't send you friend "
            "requests. They aren't told.",
            style: text.bodySmall,
          ),
          const SizedBox(height: 12),
          if (blocked.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text(
                "You haven't blocked anyone. Hold someone's message in a room's chat, or use the menu next to a "
                'player, to block or report them.',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: Palette.steel),
              ),
            ),
          for (final b in blocked)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: AvatarBadge(avatar: b.avatar, size: 40),
              title: Text(b.username),
              trailing: OutlinedButton(onPressed: () => _unblock(b.id, b.username), child: const Text('Unblock')),
            ),
        ],
      ),
    );
  }
}
