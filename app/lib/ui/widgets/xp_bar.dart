import 'package:flutter/material.dart';

import '../theme/palette.dart';

/// A glowing XP bar. [fraction] is 0–1 of the current level.
class XpBar extends StatelessWidget {
  const XpBar({super.key, required this.fraction, this.height = 10});

  final double fraction;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Palette.forgeBlack,
        borderRadius: BorderRadius.circular(height),
        border: Border.all(color: Palette.edge),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final width = c.maxWidth * (fraction.isFinite ? fraction.clamp(0.0, 1.0) : 0.0);
          // Nothing to draw yet: a blurred shadow on an empty box is wasted
          // work, and some GPU drivers handle it badly.
          if (width < 1) return const SizedBox.shrink();
          return Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: width,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(height),
                gradient: LinearGradient(
                  // Light schemes' molten is the darker accent.
                  colors: Palette.isLight
                      ? [Palette.molten, Palette.ember, Palette.glint]
                      : [Palette.ember, Palette.molten, Palette.glint],
                  stops: [0, 0.8, 1],
                ),
                boxShadow: [
                  if (width >= height) BoxShadow(color: Palette.ember.withValues(alpha: 0.6), blurRadius: height),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
