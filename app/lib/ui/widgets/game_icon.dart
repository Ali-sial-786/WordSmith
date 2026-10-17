import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/palette.dart';

/// A single-colour SVG from assets/icons, tinted, with a Material fallback
/// while the art is missing.
class GameIcon extends StatelessWidget {
  const GameIcon(
    this.name, {
    super.key,
    this.size = 24,
    this.color = Palette.whiteHeat,
  });

  final String name;
  final double size;
  final Color color;

  static const _fallbacks = <String, IconData>{
    'hammer': Icons.gavel,
    'chisel': Icons.edit,
    'sparks': Icons.auto_awesome,
    'turn': Icons.autorenew,
    'anvil': Icons.hardware,
    'scrap_bucket': Icons.delete_outline,
    'ember': Icons.local_fire_department,
    'crown': Icons.emoji_events,
    'friends': Icons.group,
    'settings': Icons.settings,
    'back': Icons.arrow_back,
    'lock': Icons.lock,
    'star': Icons.star,
    'trophy': Icons.emoji_events,
    'flame': Icons.local_fire_department,
    'map': Icons.map,
    'user': Icons.person,
  };

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/icons/$name.svg',
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    placeholderBuilder: (_) => Icon(
      _fallbacks[name] ?? Icons.circle_outlined,
      size: size,
      color: color,
    ),
    errorBuilder: (_, _, _) => Icon(
      _fallbacks[name] ?? Icons.circle_outlined,
      size: size,
      color: color,
    ),
  );
}
