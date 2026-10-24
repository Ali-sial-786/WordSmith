import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/theme.dart';
import 'forge_frame.dart';
import 'game_icon.dart';

/// A round riveted-iron button for in-game controls.
class RoundMetalButton extends StatelessWidget {
  const RoundMetalButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = 54,
    this.badge,
    this.locked = false,
    this.active = false,
    this.tooltip,
  });

  final String icon;
  final VoidCallback? onPressed;
  final double size;

  /// Small count shown at the bottom-right (e.g. hints in stock).
  final String? badge;
  final bool locked;

  /// Lit up (e.g. Chisel waiting for a cell).
  final bool active;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !locked;
    final button = GestureDetector(
      onTap: onPressed,
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: active
                          ? Palette.ember.withValues(alpha: 0.6)
                          : Colors.black.withValues(alpha: Palette.isLight ? 0.25 : 0.5),
                      blurRadius: active ? 14 : 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: KitImage(
                  active ? 'assets/ui/round_active.png' : 'assets/ui/round.png',
                  hot: active,
                  gold: active,
                  errorBuilder: (_, _, _) => _PaintedRound(active: active),
                ),
              ),
            ),
            Center(
              // Faded by its colour: an Opacity would take a layer on every frame.
              child: GameIcon(
                icon,
                size: size * 0.5,
                color: (active ? Palette.onAccent : Palette.whiteHeat).withValues(alpha: enabled ? 1 : 0.45),
              ),
            ),
            if (locked)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Palette.forgeBlack.withValues(alpha: 0.55)),
                  child: Center(
                    child: GameIcon('lock', size: size * 0.36, color: Palette.steel),
                  ),
                ),
              ),
            if (badge != null)
              Positioned(
                right: -4,
                bottom: -4,
                child: Container(
                  constraints: BoxConstraints(minWidth: size * 0.42),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: locked ? Palette.ash : Palette.ember,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Palette.forgeBlack, width: 1.5),
                  ),
                  child: Text(
                    badge!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: Fonts.ui,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      color: Palette.forgeBlack,
                      height: 1.1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// The round button as paint alone, if its rendered ring can't be loaded.
class _PaintedRound extends StatelessWidget {
  const _PaintedRound({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final s = Palette.scheme;
    final colors = !active
        ? Palette.roundFace
        : s.asRendered
        ? [Palette.molten, Palette.ember, const Color(0xFF7A2A0A)]
        : [s.plate.$2, s.plate.$1, Color.lerp(s.plate.$1, const Color(0xFF000000), 0.3)!];
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(center: const Alignment(-0.3, -0.4), colors: colors),
        border: Border.all(color: active ? Palette.fire.white : s.rim, width: 2),
      ),
    );
  }
}

/// A wide forged-plate button for menus.
class PlateButton extends StatelessWidget {
  const PlateButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
    this.sublabel,
    this.height = 56,
  });

  final String label;
  final String? sublabel;
  final String? icon;
  final VoidCallback? onPressed;
  final bool primary;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final fg = primary ? Palette.onAccent : Palette.whiteHeat;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: SizedBox(
        height: height,
        child: ForgeFrame(
          kind: primary ? ForgeFrameKind.platePrimary : ForgeFrameKind.plate,
          glint: primary && enabled,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onPressed,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    if (icon != null) ...[GameIcon(icon!, size: 26, color: fg), const SizedBox(width: 14)],
                    // Words shrink to fit the plate rather than being cut off.
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(label, maxLines: 1, style: displayStyle(primary ? 19 : 16, color: fg)),
                          ),
                          if (sublabel != null)
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                sublabel!,
                                maxLines: 1,
                                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: primary ? Palette.onAccent.withValues(alpha: 0.8) : Palette.steel,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small forged plate for actions inside cards ("Claim", "Send").
class ForgeChipButton extends StatelessWidget {
  const ForgeChipButton({super.key, required this.label, required this.onPressed, this.primary = true, this.icon});

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final String? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final fg = primary ? Palette.onAccent : Palette.whiteHeat;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: SizedBox(
        height: 42,
        child: ForgeFrame(
          kind: primary ? ForgeFrameKind.platePrimary : ForgeFrameKind.plate,
          glint: primary && enabled,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onPressed,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[GameIcon(icon!, size: 16, color: fg), const SizedBox(width: 6)],
                    Text(label, style: displayStyle(14, color: fg)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
