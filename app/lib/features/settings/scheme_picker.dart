import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/providers.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';

/// A scheme's name under its swatch.
TextStyle _nameStyle(double size, [Color? color]) => TextStyle(
  fontFamily: Fonts.ui,
  fontSize: size,
  fontWeight: FontWeight.w800,
  fontVariations: weight(800),
  color: color,
);

/// Settings: the colour scheme, as two rows of swatches that each show the
/// scheme's background, frame, accent and text. A tap applies it at once.
class SchemePicker extends ConsumerWidget {
  const SchemePicker({super.key});

  /// Every scheme in sight at once: ten make two even rows.
  static const _columns = 5;

  /// The names' size where they fit.
  static const _nameSize = 12.5;

  /// [text]'s width on one line in [style].
  static double _textWidth(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

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
              const gap = 8.0;
              final width = (c.maxWidth - (_columns - 1) * gap) / _columns;
              // Every name at one size: the largest the longest fits at.
              final widest = PaletteScheme.all.map((s) => _textWidth(s.name, _nameStyle(_nameSize))).reduce(max);
              final nameSize = _nameSize * min(1.0, (width - 2) / widest);
              return Wrap(
                spacing: gap,
                runSpacing: 10,
                children: [
                  for (final s in PaletteScheme.all)
                    SizedBox(
                      width: width,
                      child: _Swatch(
                        scheme: s,
                        selected: s.id == current.id,
                        nameSize: nameSize,
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

/// A scheme in miniature, drawn in its own colours: its background, a card
/// framed in its metal with a line of its text and highlight, and an accent
/// button. Its name goes underneath, in the current scheme's text.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.scheme, required this.selected, required this.nameSize, required this.onTap});

  final PaletteScheme scheme;
  final bool selected;
  final double nameSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = scheme;
    final radius = BorderRadius.circular(12);
    return Semantics(
      button: true,
      selected: selected,
      label: '${s.name} colours',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(15),
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
                        padding: const EdgeInsets.all(6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // A card: text and a highlight on the panel, in a frame of the scheme's metal.
                            Container(
                              height: 28,
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: s.panel,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: s.rim, width: 1.5),
                              ),
                              // Shrinks on the smallest phones rather than overflowing.
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('Aa', style: displayStyle(15, color: s.whiteHeat)),
                                    Container(
                                      width: 7,
                                      height: 7,
                                      margin: const EdgeInsets.only(left: 4),
                                      decoration: BoxDecoration(color: s.molten, shape: BoxShape.circle),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 5),
                            // An accent button.
                            Container(
                              height: 10,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(5),
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [s.plate.$2, s.plate.$1],
                                ),
                                border: Border.all(color: Color.lerp(s.rim, s.gold, 0.5)!),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (selected)
                  Positioned(
                    top: -4,
                    right: -4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Palette.forgeBlack, shape: BoxShape.circle),
                      child: Icon(Icons.check_circle, size: 18, color: Palette.molten),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // Sized to fit already; this only catches rounding.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                s.name,
                maxLines: 1,
                style: _nameStyle(nameSize, selected ? Palette.molten : Palette.whiteHeat),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
