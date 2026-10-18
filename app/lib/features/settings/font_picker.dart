import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/providers.dart';
import '../../ui/theme/theme.dart';

/// Settings: the fonts.
class FontPicker extends ConsumerWidget {
  const FontPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = FontChoice.byId(ref.watch(settingsProvider).font);
    return ListTile(
      title: const Text('Font'),
      trailing: DropdownButton<String>(
        value: current.id,
        items: [for (final f in FontChoice.all) DropdownMenuItem(value: f.id, child: Text(f.name))],
        onChanged: (id) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(font: id)),
      ),
    );
  }
}
