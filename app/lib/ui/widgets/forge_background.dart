import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/providers.dart';
import '../effects/forge_fire.dart';
import '../effects/sparks.dart';
import '../theme/palette.dart';

/// A dimmed scene image (blurred if asked) behind a screen, with an animated
/// forge fire along the bottom and drifting embers. Falls back to a warm
/// gradient while art is missing.
class ForgeBackground extends ConsumerWidget {
  const ForgeBackground({
    super.key,
    required this.image,
    required this.child,
    this.dim = 0.55,
    this.blur = 0,
    this.fire = 0.8,
    this.fireHeight = 0.42,
    this.warmth = 1,
  });

  /// Asset path, e.g. `assets/images/bg_tin.webp`.
  final String image;
  final Widget child;
  final double dim;
  final double blur;

  /// Strength (0–1) of the animated forge fire along the bottom; 0 hides it.
  final double fire;

  /// Fraction of the screen height the fire layer covers.
  final double fireHeight;

  /// How strongly to warm the picture (0 leaves it as rendered). Moonlit and
  /// cool chapters use less, so their blues survive.
  final double warmth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reducedMotion = ref.watch(settingsProvider.select((s) => s.reducedMotion));
    final light = Palette.isLight;
    // Dark text needs a pale scene: a light scheme washes the picture out
    // much more, and evenly from top to bottom.
    final wash = light ? [0.5 + 0.3 * dim, 0.55 + 0.3 * dim, 0.6 + 0.3 * dim] : [dim * 0.8, dim, dim * 1.25];
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, 0.9),
              radius: 1.3,
              colors: [
                Palette.scheme.asRendered ? Color(0xFF4A2412) : Color.lerp(Palette.forgeBlack, Palette.ember, 0.25)!,
                Palette.soot,
                Palette.forgeBlack,
              ],
              stops: [0, 0.45, 1],
            ),
          ),
        ),
        ImageFiltered(
          enabled: blur > 0,
          imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          // Warm grade: dimmed yellow firelight otherwise drifts olive. Other
          // schemes tint the picture their own colour instead.
          child: ColorFiltered(
            colorFilter: ColorFilter.matrix(
              SchemeFilters.scene() ??
                  [
                    1 + 0.06 * warmth, 0, 0, 0, 0, //
                    0, 1 - 0.14 * warmth, 0, 0, 0, //
                    0, 0, 1 - 0.3 * warmth, 0, 0, //
                    0, 0, 0, 1, 0, //
                  ],
            ),
            child: Image.asset(
              image,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [for (final a in wash) Palette.forgeBlack.withValues(alpha: a.clamp(0.0, 1.0))],
            ),
          ),
        ),
        if (fire > 0)
          Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: fireHeight,
              widthFactor: 1,
              // On a pale scene the coals would be a dark smudge: a lower glow.
              // Other schemes burn in their own accent (a gas forge's blue, say).
              child: SchemeFire(
                child: ForgeFire(intensity: light ? fire * 0.5 : fire, animate: !reducedMotion),
              ),
            ),
          ),
        if (!reducedMotion) const EmberDrift(count: 22),
        child,
      ],
    );
  }
}

/// The forge's fire burning in the scheme's accent (orange, as rendered, for the forge).
class SchemeFire extends StatelessWidget {
  const SchemeFire({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final matrix = SchemeFilters.fire();
    return matrix == null ? child : ColorFiltered(colorFilter: ColorFilter.matrix(matrix), child: child);
  }
}
