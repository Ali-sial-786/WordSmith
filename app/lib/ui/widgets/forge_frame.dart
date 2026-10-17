import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/providers.dart';
import '../theme/palette.dart';

/// The rendered metal frames of the UI kit (art/blender/ui_kit.py), drawn as
/// nine-slice images at 3×. Each falls back to a painted look if its image
/// can't be loaded.
enum ForgeFrameKind {
  /// A dark forged-iron menu button with a polished bronze rim.
  plate('assets/ui/plate.png', Size(160, 64), Rect.fromLTRB(20, 20, 140, 44), 14),

  /// The glowing hot-metal button with a gold rim.
  platePrimary('assets/ui/plate_primary.png', Size(160, 64), Rect.fromLTRB(20, 20, 140, 44), 14),

  /// A card: dark brushed iron in a riveted steel-and-bronze frame.
  panel('assets/ui/panel.png', Size(96, 96), Rect.fromLTRB(24, 24, 72, 72), 18),

  /// A card with a gold frame, for rewards waiting.
  panelGold('assets/ui/panel_gold.png', Size(96, 96), Rect.fromLTRB(24, 24, 72, 72), 18),

  /// A small pill for chips and badges.
  tab('assets/ui/tab.png', Size(48, 24), Rect.fromLTRB(12, 10, 36, 14), 12);

  const ForgeFrameKind(this.asset, this.size, this.slice, this.radius);

  final String asset;

  /// The image's size in logical pixels.
  final Size size;

  /// The stretchable middle, in logical pixels (image pixels / 3).
  final Rect slice;

  /// Corner radius, for shadows, ink and the painted fallback.
  final double radius;

  /// The smallest box the nine slices fit in: the corners can't shrink.
  Size get minSize => Size(slice.left + size.width - slice.right, slice.top + size.height - slice.bottom);

  BoxDecoration get fallback => switch (this) {
    plate => BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF4A433D), Color(0xFF332D29), Color(0xFF241F1C)],
      ),
      border: Border.all(color: const Color(0xFF8C6B47), width: 1.5),
    ),
    platePrimary => BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFFC45E), Palette.molten, Palette.ember],
      ),
      border: Border.all(color: const Color(0xFFFFE2A8), width: 1.5),
    ),
    panel || tab => BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      color: Palette.soot.withValues(alpha: 0.92),
      border: Border.all(color: const Color(0xFF5C4733)),
    ),
    panelGold => BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      color: const Color(0xFF2A2116),
      border: Border.all(color: Palette.gold.withValues(alpha: 0.8)),
    ),
  };
}

/// Draws [kind]'s frame behind [child].
class ForgeFrame extends StatelessWidget {
  const ForgeFrame({
    super.key,
    required this.kind,
    this.child,
    this.padding = EdgeInsets.zero,
    this.shadow = true,
    this.glint = false,
  });

  final ForgeFrameKind kind;
  final Widget? child;
  final EdgeInsetsGeometry padding;

  /// A soft drop shadow (glowing for the primary plate).
  final bool shadow;

  /// A band of light sweeps across now and then, for things that want a tap.
  final bool glint;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(kind.radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          if (shadow && kind == ForgeFrameKind.platePrimary)
            BoxShadow(color: Palette.ember.withValues(alpha: 0.45), blurRadius: 18, offset: const Offset(0, 3))
          else if (shadow)
            BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Stack(
        // The child gets the frame's own constraints, so a fixed-height
        // button's ink fills the whole plate.
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, c) {
                final painted = DecoratedBox(decoration: kind.fallback);
                // Smaller than the corners (mid-animation, say): paint it.
                if (c.maxWidth < kind.minSize.width || c.maxHeight < kind.minSize.height) return painted;
                return Image.asset(
                  kind.asset,
                  centerSlice: kind.slice,
                  fit: BoxFit.fill,
                  scale: 3,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => painted,
                );
              },
            ),
          ),
          if (glint)
            Positioned.fill(
              child: ClipRRect(borderRadius: radius, child: const _Glint()),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// A forged card: [ForgeFrameKind.panel], or the gold one when [gold].
class ForgePanel extends StatelessWidget {
  const ForgePanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.gold = false,
    this.glint = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool gold;
  final bool glint;

  @override
  Widget build(BuildContext context) => ForgeFrame(
    kind: gold ? ForgeFrameKind.panelGold : ForgeFrameKind.panel,
    padding: padding,
    glint: glint,
    child: child,
  );
}

/// A diagonal sheen that crosses the frame every few seconds. Still with
/// reduced motion.
class _Glint extends ConsumerStatefulWidget {
  const _Glint();

  @override
  ConsumerState<_Glint> createState() => _GlintState();
}

class _GlintState extends ConsumerState<_Glint> with SingleTickerProviderStateMixin {
  // Each frame starts at a different point, so a screen of them doesn't
  // flash in step.
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 5200),
    value: Random().nextDouble(),
  );

  @override
  void initState() {
    super.initState();
    if (!ref.read(settingsProvider).reducedMotion) _sweep.repeat();
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _sweep,
      builder: (context, _) {
        // Crosses in the first quarter of the loop, then rests off-frame.
        final t = (_sweep.value / 0.25).clamp(0.0, 1.0);
        if (t >= 1) return const SizedBox.expand();
        final x = -1.6 + 3.2 * Curves.easeInOut.transform(t);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(x - 0.5, -1),
              end: Alignment(x + 0.5, 1),
              colors: [
                Colors.white.withValues(alpha: 0),
                Colors.white.withValues(alpha: 0.22),
                Colors.white.withValues(alpha: 0),
              ],
              stops: const [0.35, 0.5, 0.65],
            ),
          ),
        );
      },
    ),
  );
}
