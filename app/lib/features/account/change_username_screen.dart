import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/account.dart';
import '../../net/api_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/forge_frame.dart';
import '../../ui/widgets/gold_field.dart';
import '../../ui/widgets/metal_button.dart';

final _validName = RegExp(r'^[A-Za-z0-9_]{3,16}$');

/// A new smith name (server/README.md, `POST /v1/me/username`): setup's
/// rules, as often as the player likes. Reached from Settings → Account.
class ChangeUsernameScreen extends ConsumerStatefulWidget {
  const ChangeUsernameScreen({super.key});

  @override
  ConsumerState<ChangeUsernameScreen> createState() => _ChangeUsernameScreenState();
}

class _ChangeUsernameScreenState extends ConsumerState<ChangeUsernameScreen> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final current = ref.read(accountProvider).server?.username;
    if (!_validName.hasMatch(name)) {
      setState(() => _error = 'Use 3–16 letters, numbers or _.');
      return;
    }
    if (name == current) {
      setState(() => _error = "That's your name already.");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final n = ref.read(accountProvider.notifier);
    try {
      await n.changeUsername(name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("You're now $name.")));
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.friendly);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final server = ref.watch(accountProvider.select((a) => a.server));
    return Scaffold(
      appBar: AppBar(title: Text('Your smith name', style: displayStyle(22)), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ForgePanel(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                AvatarBadge(avatar: server?.avatar ?? avatarIds.first, size: 52),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Friends know you as', style: text.labelMedium?.copyWith(color: Palette.steel)),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(server?.username ?? '?', style: displayStyle(24, color: Palette.gold)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Text('A new name', style: text.titleMedium),
          const SizedBox(height: 10),
          GoldTextField(
            key: const ValueKey('new-username'),
            controller: _name,
            hint: 'New smith name',
            icon: Icons.edit_outlined,
            maxLength: 16,
            enabled: !_busy,
            error: _error,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 6),
          for (final rule in const [
            '3–16 letters, numbers or _',
            'Nobody else can have it, whatever the capitals',
            'Friends see it everywhere at once, and find you by it',
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 8),
                    child: Icon(Icons.local_fire_department, size: 14, color: Palette.molten),
                  ),
                  Expanded(child: Text(rule, style: text.bodySmall)),
                ],
              ),
            ),
          const SizedBox(height: 24),
          PlateButton(
            label: _busy ? 'Forging…' : 'Change name',
            icon: 'anvil',
            primary: true,
            onPressed: _busy ? null : _submit,
          ),
        ],
      ),
    );
  }
}
