import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/theme.dart';
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
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(-0.3, -0.4),
                  colors: active
                      ? const [Palette.molten, Palette.ember, Color(0xFF7A2A0A)]
                      : const [Color(0xFF55504B), Color(0xFF34302C), Color(0xFF1E1B19)],
                ),
                border: Border.all(
                  color: active ? Palette.whiteHeat : const Color(0xFF8C6B47),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: active
                        ? Palette.ember.withValues(alpha: 0.6)
                        : Colors.black.withValues(alpha: 0.5),
                    blurRadius: active ? 14 : 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Center(
                child: Opacity(
                  opacity: enabled ? 1 : 0.45,
                  child: GameIcon(
                    icon,
                    size: size * 0.5,
                    color: active ? Palette.darkLetter : Palette.whiteHeat,
                  ),
                ),
              ),
            ),
            if (locked)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Palette.forgeBlack.withValues(alpha: 0.55),
                  ),
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
                    style: const TextStyle(
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
    final fg = primary ? Palette.darkLetter : Palette.whiteHeat;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: primary
                    ? const [Color(0xFFFFC45E), Palette.molten, Palette.ember]
                    : const [Color(0xFF4A433D), Color(0xFF332D29), Color(0xFF241F1C)],
              ),
              border: Border.all(
                color: primary ? const Color(0xFFFFE2A8) : const Color(0xFF8C6B47),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: primary
                      ? Palette.ember.withValues(alpha: 0.45)
                      : Colors.black.withValues(alpha: 0.4),
                  blurRadius: primary ? 18 : 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  if (icon != null) ...[
                    GameIcon(icon!, size: 26, color: fg),
                    const SizedBox(width: 14),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: displayStyle(primary ? 19 : 16, color: fg),
                        ),
                        if (sublabel != null)
                          Text(
                            sublabel!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: primary
                                  ? Palette.darkLetter.withValues(alpha: 0.8)
                                  : Palette.steel,
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
    );
  }
}
