import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/providers.dart';
import '../../ui/theme/palette.dart';

/// Settings: the colour scheme.
class SchemePicker extends ConsumerWidget {
  const SchemePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = PaletteScheme.byId(ref.watch(settingsProvider).colorScheme);
    return ListTile(
      title: const Text('Colours'),
      trailing: DropdownButton<String>(
        value: current.id,
        items: [for (final s in PaletteScheme.all) DropdownMenuItem(value: s.id, child: Text(s.name))],
        onChanged: (id) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(colorScheme: id)),
      ),
    );
  }
}
