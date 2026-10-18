import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/palette.dart';

/// When the hammer lands after a Hammer Strike starts. The struck cell's
/// own reveal (its pop and burst of sparks) is held back until then.
const hammerImpact = Duration(milliseconds: 380);

/// The whole swing, from wind-up to the hammer lifting away.
const _swing = Duration(milliseconds: 900);

/// The rendered hammer (art/blender/hammer_sprite.py): its size, and where
/// its striking face and grip are, as fractions from the top left (printed
/// by `post.py hammer`).
const _sprite = 'assets/images/hammer_strike.png';
const _aspect = 234 / 384;
const _face = Offset(0.0971, 0.1661);
const _grip = Offset(0.3006, 0.9743);

/// The Hammer Strike hint: a hammer winds up over [cell], swings down and
/// lands on it at [hammerImpact] with a flash, then lifts away and fades.
/// [mirror] swings it from the left (for cells on the right of the grid).
class HammerStrike extends StatefulWidget {
  const HammerStrike({super.key, required this.cell, this.mirror = false, this.onDone});

  /// Loads the hammer ahead of time, so the first strike isn't missing it.
  static Future<void> precache(BuildContext context) => precacheImage(const AssetImage(_sprite), context);

  /// The struck cell, in the grid's coordinates.
  final Rect cell;
  final bool mirror;

  /// The hammer has lifted away and faded.
  final VoidCallback? onDone;

  @override
  State<HammerStrike> createState() => _HammerStrikeState();
}

class _HammerStrikeState extends State<HammerStrike> with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(vsync: this, duration: _swing)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone?.call();
    })
    ..forward();

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  /// The hammer's angle from where it lands (radians, positive lifts it),
  /// and how opaque it is, [ms] into the swing.
  static (double, double) _pose(double ms) {
    const impact = 380.0;
    if (ms < 140) {
      // Appears raised and draws back a little further.
      final k = Curves.easeOut.transform(ms / 140);
      return (1.35 + 0.2 * k, k);
    }
    if (ms < impact) {
      // The swing: faster and faster.
      final k = Curves.easeInCubic.transform((ms - 140) / (impact - 140));
      return (1.55 * (1 - k), 1);
    }
    if (ms < 480) {
      // A small bounce off the metal.
      final k = (ms - impact) / 100;
      return (0.16 * sin(k * pi * 0.5), 1);
    }
    // Lifts away and fades.
    final k = Curves.easeOut.transform(((ms - 480) / 420).clamp(0.0, 1.0));
    return (0.16 + 0.5 * k, 1 - k);
  }

  @override
  Widget build(BuildContext context) {
    final cell = widget.cell;
    // The head is about a cell and a bit long.
    final w = cell.width * 1.3;
    final h = w / _aspect;
    final dir = widget.mirror ? -1.0 : 1.0;
    final grip = Offset((widget.mirror ? 1 - _grip.dx : _grip.dx) * w, _grip.dy * h);
    final face = Offset((widget.mirror ? 1 - _face.dx : _face.dx) * w, _face.dy * h);
    // Landed, the face points down onto the cell and the handle runs off to
    // the side; work out where the grip (the pivot) must be for that.
    final landed = -pi / 2 * dir;
    final target = cell.center.translate(0, -cell.height * 0.12);
    final pivot = target - _rotate(face - grip, landed);

    Widget hammer(double angle, double opacity) => Positioned(
      left: pivot.dx - grip.dx,
      top: pivot.dy - grip.dy,
      width: w,
      height: h,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.rotate(
          angle: angle,
          origin: grip - Offset(w / 2, h / 2),
          child: Transform.flip(
            flipX: widget.mirror,
            child: Image.asset(_sprite, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
          ),
        ),
      ),
    );

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _t,
        builder: (context, _) {
          final ms = _t.value * _swing.inMilliseconds;
          final (lift, opacity) = _pose(ms);
          final swinging = ms > 220 && ms < 380;
          // The flash where it lands.
          final flash = ((ms - 370) / 260).clamp(0.0, 1.0);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // A blur of where it just was, at full speed.
              if (swinging)
                for (final (lag, a) in const [(0.32, 0.18), (0.16, 0.32)]) hammer(landed + dir * (lift + lag), a),
              if (opacity > 0) hammer(landed + dir * lift, opacity),
              if (flash > 0 && flash < 1)
                Positioned.fromRect(
                  rect: Rect.fromCircle(center: target, radius: cell.width * (0.4 + 0.9 * flash)),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          Colors.white.withValues(alpha: 0.9 * (1 - flash)),
                          Palette.fire.molten.withValues(alpha: 0.6 * (1 - flash)),
                          Palette.fire.ember.withValues(alpha: 0),
                        ],
                        stops: const [0.0, 0.35, 1.0],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static Offset _rotate(Offset v, double a) => Offset(v.dx * cos(a) - v.dy * sin(a), v.dx * sin(a) + v.dy * cos(a));
}
