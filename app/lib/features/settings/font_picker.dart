import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/providers.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';

/// Settings: the fonts. Each choice is shown in its own fonts, with a few
/// letters on mold tiles, and applies as soon as it's tapped.
class FontPicker extends ConsumerWidget {
  const FontPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = FontChoice.byId(ref.watch(settingsProvider).font);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ListTile(title: Text('Font'), subtitle: Text('Titles and the letters you forge')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            children: [
              for (final f in FontChoice.all)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _Option(
                    font: f,
                    selected: f.id == current.id,
                    onTap: () => ref.read(settingsProvider.notifier).update((s) => s.copyWith(font: f.id)),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.font, required this.selected, required this.onTap});

  final FontChoice font;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    inMutuallyExclusiveGroup: true,
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        decoration: BoxDecoration(
          color: selected ? Color.lerp(Palette.soot, Palette.ember, 0.18) : Palette.soot.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? Palette.molten : Palette.ash, width: selected ? 2 : 1),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    font.name,
                    style: displayStyle(20, font: font, color: selected ? Palette.molten : null),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    font.blurb,
                    style: TextStyle(
                      fontFamily: font.ui,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      fontVariations: weight(500),
                      color: Palette.steel,
                    ),
                  ),
                ],
              ),
            ),
            for (final letter in const ['C', 'G', 'Q']) _Tile(letter: letter, font: font),
            const SizedBox(width: 10),
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected ? Palette.molten : Palette.ash,
              size: 24,
            ),
          ],
        ),
      ),
    ),
  );
}

/// A letter on a little bronze mold tile, the size the molds' smallest are.
/// Only a sample, so screen readers skip it.
class _Tile extends StatelessWidget {
  const _Tile({required this.letter, required this.font});

  final String letter;
  final FontChoice font;

  @override
  Widget build(BuildContext context) {
    final metal = MetalStyle.forChapter('bronze');
    return Container(
      width: 32,
      height: 32,
      margin: const EdgeInsets.only(left: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [metal.highlight, metal.base],
        ),
      ),
      child: ExcludeSemantics(
        child: Text(
          letter,
          style: letterStyle(20, font: font, color: metal.letter),
        ),
      ),
    );
  }
}
