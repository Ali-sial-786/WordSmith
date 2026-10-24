import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:vector_graphics/vector_graphics_compat.dart' show RenderingStrategy;

import '../theme/palette.dart';

/// A single-colour SVG from assets/icons, tinted, with a Material fallback
/// while the art is missing.
///
/// Drawn from a raster made once per icon and size: tinting the vector
/// picture takes an offscreen layer on every frame, and the forge fire
/// redraws the screen many times a second.
class GameIcon extends StatelessWidget {
  const GameIcon(this.name, {super.key, this.size = 24, this.color});

  final String name;
  final double size;

  /// White heat unless given.
  final Color? color;

  Color get _color => color ?? Palette.whiteHeat;

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
    'scroll': Icons.receipt_long,
    'gift': Icons.card_giftcard,
    'bellows': Icons.whatshot,
    'calendar': Icons.calendar_month,
    'book': Icons.menu_book,
    'blueprint': Icons.architecture,
    'gilded': Icons.diamond,
    'swap': Icons.swap_horiz,
    'speaker': Icons.volume_up,
  };

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/icons/$name.svg',
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(_color, BlendMode.srcIn),
    renderingStrategy: RenderingStrategy.raster,
    placeholderBuilder: (_) => Icon(_fallbacks[name] ?? Icons.circle_outlined, size: size, color: _color),
    errorBuilder: (_, _, _) => Icon(_fallbacks[name] ?? Icons.circle_outlined, size: size, color: _color),
  );
}
