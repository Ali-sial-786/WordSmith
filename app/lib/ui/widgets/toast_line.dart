import 'package:flutter/material.dart';

import '../theme/palette.dart';

/// A one-line message that slides in above the anvil and fades out.
class ToastLine extends StatefulWidget {
  const ToastLine({super.key});

  @override
  State<ToastLine> createState() => ToastLineState();
}

class ToastLineState extends State<ToastLine> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );
  String _text = '';
  Color _color = Palette.whiteHeat;

  void show(String text, {Color color = Palette.whiteHeat}) {
    setState(() {
      _text = text;
      _color = color;
    });
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          if (_text.isEmpty || !_c.isAnimating && _c.value == 1) {
            return const SizedBox.shrink();
          }
          final t = _c.value;
          final opacity = t < 0.1 ? t / 0.1 : (t > 0.75 ? (1 - t) / 0.25 : 1.0);
          return Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, 6 * (1 - (t / 0.1).clamp(0.0, 1.0))),
              child: Center(
                // A long message shrinks to fit rather than running off the edge.
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _text,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: _color,
                        shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
