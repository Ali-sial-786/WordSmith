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

/// When the name may change again, for players: "Tue, Oct 21 (in 3 days)".
String nextChangeLabel(BuildContext context, DateTime at) {
  final left = at.difference(DateTime.now());
  final days = (left.inHours / 24).ceil();
  final hours = left.inMinutes <= 60 ? 1 : (left.inMinutes / 60).ceil();
  final when = left.inHours < 24
      ? 'in $hours ${hours == 1 ? 'hour' : 'hours'}'
      : 'in $days ${days == 1 ? 'day' : 'days'}';
  return '${MaterialLocalizations.of(context).formatMediumDate(at)} ($when)';
}

/// A new smith name (server/README.md, `POST /v1/me/username`): setup's
/// rules, at most once a week. Reached from Settings → Account.
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
      if (!mounted) return;
      final next = e.nextChangeAt;
      setState(
        () =>
            _error = next != null ? 'You can change your name again on ${nextChangeLabel(context, next)}.' : e.friendly,
      );
      // Changed on another phone? The profile says when, from now on.
      if (e.code == 'too_soon') await n.sync();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final server = ref.watch(accountProvider.select((a) => a.server));
    final locked = server?.usernameLocked ?? false;
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
            enabled: !locked && !_busy,
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
            'You can change it once a week',
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
          if (locked && server?.nextUsernameChangeAt != null) ...[
            const SizedBox(height: 14),
            ForgePanel(
              padding: const EdgeInsets.all(12),
              gold: true,
              child: Row(
                children: [
                  Icon(Icons.hourglass_bottom, color: Palette.gold),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'You changed your name recently. You can change it again on '
                      '${nextChangeLabel(context, server!.nextUsernameChangeAt!)}.',
                      style: text.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          PlateButton(
            label: _busy ? 'Forging…' : 'Change name',
            icon: 'anvil',
            primary: true,
            onPressed: locked || _busy ? null : _submit,
          ),
        ],
      ),
    );
  }
}
