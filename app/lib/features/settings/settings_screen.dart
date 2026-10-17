import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_info.dart';
import '../../game/providers.dart';
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
