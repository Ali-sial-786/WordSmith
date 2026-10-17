import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/theme.dart';

enum PreviewResult { good, bonus, repeat, bad }

/// The word being swiped, shown above the anvil. After a submit it plays a
/// short reaction (glow, shake…) and fades.
class WordPreview extends StatefulWidget {
  const WordPreview({super.key, required this.word});

  final String word;

  @override
  State<WordPreview> createState() => WordPreviewState();
}

class WordPreviewState extends State<WordPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _react = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  String _shown = '';
  PreviewResult? _result;

  /// Plays the reaction for [word] after the finger lifts.
  void react(String word, PreviewResult result) {
    setState(() {
      _shown = word;
      _result = result;
    });
    _react.forward(from: 0).whenComplete(() {
      if (mounted && widget.word.isEmpty) setState(() => _shown = '');
    });
  }

  @override
  void didUpdateWidget(WordPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.word.isNotEmpty) {
      _react.stop();
      _shown = widget.word;
      _result = null;
    }
  }

  @override
  void dispose() {
    _react.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: AnimatedBuilder(
        animation: _react,
        builder: (context, _) {
          if (_shown.isEmpty) return const SizedBox.shrink();
          final t = _result == null ? 0.0 : _react.value;
          final reacting = _result != null;
          final color = switch (_result) {
            PreviewResult.good => Palette.molten,
            PreviewResult.bonus => Palette.verdigris,
            PreviewResult.repeat => Palette.steel,
            PreviewResult.bad => Palette.quenchRed,
            null => Palette.ember,
          };
          var dx = 0.0;
          var dy = 0.0;
          var opacity = 1.0;
          var scale = 1.0;
          if (reacting) {
            opacity = (1 - Curves.easeIn.transform(t)).clamp(0.0, 1.0);
            switch (_result!) {
              case PreviewResult.bad:
                dx = sin(t * pi * 6) * 10 * (1 - t);
              case PreviewResult.good:
                dy = -24 * Curves.easeOut.transform(t);
                scale = 1 + 0.15 * t;
              case PreviewResult.bonus:
                dx = -60 * Curves.easeIn.transform(t);
                dy = 20 * t;
                scale = 1 - 0.4 * t;
              case PreviewResult.repeat:
                scale = 1 + 0.08 * sin(t * pi);
            }
          }
          return Opacity(
            opacity: opacity,
            child: Transform.translate(
              offset: Offset(dx, dy),
              child: Transform.scale(
                scale: scale,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: Palette.forgeBlack.withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: color, width: 2),
                      boxShadow: [
                        BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 16),
                      ],
                    ),
                    child: Text(
                      _shown,
                      style: letterStyle(26, color: Palette.whiteHeat).copyWith(
                        letterSpacing: 4,
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
