import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/providers.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';

/// Settings: the colour scheme, as a grid of swatches that each show the
/// scheme's background, accent and text. A tap applies it at once.
class SchemePicker extends ConsumerWidget {
  const SchemePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = PaletteScheme.byId(ref.watch(settingsProvider.select((s) => s.colorScheme)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Colours', style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, c) {
              const gap = 10.0;
              final width = (c.maxWidth - 2 * gap) / 3;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final s in PaletteScheme.all)
                    SizedBox(
                      width: width,
                      child: _Swatch(
                        scheme: s,
                        selected: s.id == current.id,
                        onTap: () => ref
                            .read(settingsProvider.notifier)
                            .update((settings) => settings.copyWith(colorScheme: s.id)),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// A scheme in miniature: its background, a framed card with a line of its
/// text, and an accent button. Drawn in the scheme's own colours.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.scheme, required this.selected, required this.onTap});

  final PaletteScheme scheme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = scheme;
    final radius = BorderRadius.circular(14);
    return Semantics(
      button: true,
      selected: selected,
      label: '${s.name} colours',
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(17),
          // The selected ring, in the current scheme's highlight.
          border: Border.all(color: selected ? Palette.molten : Colors.transparent, width: 2.5),
        ),
        child: Material(
          color: s.forgeBlack,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: s.rim.withValues(alpha: 0.7)),
              ),
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // A card: text on the panel, in a frame of the scheme's metal.
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                    decoration: BoxDecoration(
                      color: s.panel,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: s.rim, width: 1.5),
                    ),
                    child: Row(
                      children: [
                        // Shrinks on the smallest phones rather than overflowing.
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text('Aa', style: displayStyle(16, color: s.whiteHeat)),
                          ),
                        ),
                        for (final dot in [s.molten, s.gold])
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(left: 3),
                            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  // An accent button.
                  Container(
                    height: 12,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [s.plate.$2, s.plate.$1],
                      ),
                      border: Border.all(color: Color.lerp(s.rim, s.gold, 0.5)!),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: Fonts.ui,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            fontVariations: weight(800),
                            color: s.whiteHeat,
                          ),
                        ),
                      ),
                      if (selected) Icon(Icons.check_circle, size: 16, color: s.molten),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
