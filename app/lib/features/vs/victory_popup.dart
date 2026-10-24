import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../ui/effects/sparks.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_frame.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/metal_button.dart';

/// "YOU WON!" over everything, for winning a Versus or Team Versus series:
/// a gold crown, the score, sparks flying (unless motion is reduced), and a
/// button on to the podium. A tap anywhere closes it too.
Future<void> showVictoryPopup(
  BuildContext context, {
  required String title,
  required String line,
  bool reducedMotion = false,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: 'Close',
  barrierColor: Palette.forgeBlack.withValues(alpha: 0.78),
  transitionDuration: Duration(milliseconds: reducedMotion ? 0 : 420),
  transitionBuilder: (context, a, _, child) => FadeTransition(
    opacity: a,
    child: ScaleTransition(
      scale: Tween(begin: 0.7, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)),
      child: child,
    ),
  ),
  pageBuilder: (context, _, _) => _VictoryCard(title: title, line: line, reducedMotion: reducedMotion),
);

class _VictoryCard extends StatefulWidget {
  const _VictoryCard({required this.title, required this.line, required this.reducedMotion});

  final String title;
  final String line;
  final bool reducedMotion;

  @override
  State<_VictoryCard> createState() => _VictoryCardState();
}

class _VictoryCardState extends State<_VictoryCard> {
  final _sparks = GlobalKey<SparkFieldState>();
  final _crown = GlobalKey();
  Timer? _bursts;
  int _burst = 0;

  @override
  void initState() {
    super.initState();
    if (widget.reducedMotion) return;
    _bursts = Timer.periodic(const Duration(milliseconds: 450), (t) {
      if (!mounted || ++_burst > 6) return t.cancel();
      final box = _crown.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final centre = box.localToGlobal(box.size.center(Offset.zero));
      _sparks.currentState?.burst(
        centre,
        count: 26,
        speed: 320,
        spread: pi * 2,
        colors: [Palette.molten, Palette.gold, Palette.whiteHeat, Palette.ember],
      );
    });
  }

  @override
  void dispose() {
    _bursts?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SparkField(
      key: _sparks,
      intensity: widget.reducedMotion ? 0 : 1,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Material(
            type: MaterialType.transparency,
            child: ForgePanel(
              key: const ValueKey('victory-popup'),
              gold: true,
              glint: !widget.reducedMotion,
              padding: const EdgeInsets.fromLTRB(22, 26, 22, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    key: _crown,
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        center: const Alignment(-0.3, -0.4),
                        colors: [const Color(0xFFFFE2A8), Palette.gold, const Color(0xFF8A5A1C)],
                      ),
                      boxShadow: [BoxShadow(color: Palette.ember.withValues(alpha: 0.7), blurRadius: 36)],
                    ),
                    child: Center(child: GameIcon('crown', size: 54, color: Palette.darkLetter)),
                  ),
                  const SizedBox(height: 16),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      widget.title,
                      textAlign: TextAlign.center,
                      style: displayStyle(
                        40,
                        color: Palette.molten,
                      ).copyWith(shadows: [Shadow(color: Palette.ember, blurRadius: 28)]),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(widget.line, textAlign: TextAlign.center, style: text.titleMedium),
                  const SizedBox(height: 20),
                  PlateButton(
                    label: 'See the podium',
                    icon: 'trophy',
                    primary: true,
                    onPressed: () => Navigator.of(context).pop(),
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
