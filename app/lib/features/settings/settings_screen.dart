import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_info.dart';
import '../../auth/auth_service.dart';
import '../../game/account.dart';
import '../../game/providers.dart';
import '../../net/api_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text('Settings', style: displayStyle(22)), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          _Slider(
            label: 'Sound effects',
            value: s.sfxVolume,
            onChanged: (v) => n.update((s) => s.copyWith(sfxVolume: v)),
          ),
          _Slider(
            label: 'Forge ambience',
            value: s.ambienceVolume,
            onChanged: (v) => n.update((s) => s.copyWith(ambienceVolume: v)),
          ),
          SwitchListTile(
            title: const Text('Vibration'),
            value: s.haptics,
            onChanged: (v) => n.update((s) => s.copyWith(haptics: v)),
          ),
          SwitchListTile(
            title: const Text('Reduce motion'),
            subtitle: const Text('Fewer sparks and drifting embers'),
            value: s.reducedMotion,
            onChanged: (v) => n.update((s) => s.copyWith(reducedMotion: v)),
          ),
          const _AccountSection(),
          const Divider(height: 32),
          ListTile(
            title: const Text('Credits'),
            subtitle: const Text('Fonts, sounds, icons and word lists'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/credits'),
          ),
          ListTile(
            title: const Text('Version'),
            trailing: Text(appVersion, style: text.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider({required this.label, required this.value, required this.onChanged});

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(label),
    subtitle: Slider(value: value, onChanged: onChanged),
  );
}

class _AccountSection extends ConsumerWidget {
  const _AccountSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final n = ref.read(accountProvider.notifier);
    if (account.phase == AccountPhase.unavailable) return const SizedBox.shrink();
    final signedIn = account.user != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Account', style: Theme.of(context).textTheme.titleMedium),
        ),
        if (!signedIn)
          ListTile(
            title: const Text('Sign in'),
            subtitle: const Text('Keep your progress safe and play with friends'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/sign-in'),
          )
        else ...[
          ListTile(
            title: Text(account.server?.username ?? 'Signed in'),
            subtitle: Text(account.user?.email ?? ''),
            trailing: account.syncing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: 'Sync now',
                    icon: const Icon(Icons.sync),
                    onPressed: n.sync,
                  ),
          ),
          ListTile(title: const Text('Sign out'), onTap: n.signOut),
          ListTile(
            title: const Text('Delete account', style: TextStyle(color: Palette.quenchRed)),
            subtitle: const Text('Removes your account, progress and friends for good'),
            onTap: () => showDialog<void>(context: context, builder: (_) => const _DeleteDialog()),
          ),
        ],
      ],
    );
  }
}

class _DeleteDialog extends ConsumerStatefulWidget {
  const _DeleteDialog();

  @override
  ConsumerState<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends ConsumerState<_DeleteDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(accountProvider.notifier).deleteAccount(_password.text);
      if (mounted) Navigator.of(context).pop();
    } on AuthFailure catch (e) {
      setState(() => _error = e.message);
    } on ApiException catch (e) {
      setState(() => _error = e.friendly);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Delete your account?'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Your smith, progress, hints and friends will be deleted on the '
          'server and on this phone. This can\'t be undone.',
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Confirm your password'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: const TextStyle(color: Palette.quenchRed)),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
        child: const Text('Keep it'),
      ),
      TextButton(
        onPressed: _busy ? null : _delete,
        child: const Text('Delete', style: TextStyle(color: Palette.quenchRed)),
      ),
    ],
  );
}
