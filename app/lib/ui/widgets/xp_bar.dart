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
        border: Border.all(color: const Color(0xFF5C4733)),
      ),
      child: LayoutBuilder(
        builder: (context, c) => Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: c.maxWidth * fraction.clamp(0.0, 1.0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(height),
              gradient: const LinearGradient(
                colors: [Palette.ember, Palette.molten, Palette.whiteHeat],
                stops: [0, 0.8, 1],
              ),
              boxShadow: [
                BoxShadow(
                  color: Palette.ember.withValues(alpha: 0.6),
                  blurRadius: height,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
