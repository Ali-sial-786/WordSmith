import 'package:flutter/material.dart';

import '../../engine/progression.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import 'rank_badge.dart';

/// "+45 XP", and a glowing level-up badge, popping in after a match.
class XpAwardBanner extends StatelessWidget {
  const XpAwardBanner({super.key, required this.xp, required this.level, required this.levelUps});

  final int xp;
  final int level;
  final int levelUps;

  @override
  Widget build(BuildContext context) {
    final leveled = levelUps > 0;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.elasticOut,
      builder: (context, t, child) => Transform.scale(
        scale: 0.5 + 0.5 * t,
        child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
      ),
      child: Column(
        children: [
          Text('+$xp XP', style: displayStyle(26, color: Palette.molten)),
          if (leveled) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Palette.ember, Palette.molten]),
                borderRadius: BorderRadius.circular(22),
                boxShadow: [BoxShadow(color: Palette.ember.withValues(alpha: 0.7), blurRadius: 22)],
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RankBadge(rank: Rank.forLevel(level), size: 24),
                      const SizedBox(width: 8),
                      Text('LEVEL UP!', style: displayStyle(20, color: Palette.forgeBlack)),
                    ],
                  ),
                  Text(
                    'Smith Level $level · ${Rank.forLevel(level).title}',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Palette.forgeBlack),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
