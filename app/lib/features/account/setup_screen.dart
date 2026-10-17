import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../game/account.dart';
import '../../net/api_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/metal_button.dart';

final _validName = RegExp(r'^[A-Za-z0-9_]{3,16}$');

/// First-time setup: pick a smith name (forever) and an emblem.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _name = TextEditingController();
  String _avatar = avatarIds.first;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (!_validName.hasMatch(name)) {
      setState(() => _error = 'Use 3–16 letters, numbers or _.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountProvider.notifier).setup(name, _avatar);
      if (mounted) context.go('/');
    } on ApiException catch (e) {
      setState(() => _error = e.friendly);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Your smith', style: displayStyle(22)),
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Pick a name', style: text.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Friends find you by it. It can\'t be changed later.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _name,
            maxLength: 16,
            decoration: const InputDecoration(
              labelText: 'Smith name',
              helperText: '3–16 letters, numbers or _',
            ),
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 16),
          Text('Pick an emblem', style: text.titleMedium),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            children: [
              for (final id in avatarIds)
                GestureDetector(
                  onTap: () => setState(() => _avatar = id),
                  child: AvatarBadge(avatar: id, size: 64, selected: id == _avatar),
                ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: text.bodyMedium?.copyWith(color: Palette.quenchRed)),
          ],
          const SizedBox(height: 22),
          PlateButton(
            label: _busy ? 'Forging…' : 'Start forging',
            primary: true,
            onPressed: _busy ? null : _submit,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : () => ref.read(accountProvider.notifier).signOut().then((_) {
              if (context.mounted) context.go('/');
            }),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
