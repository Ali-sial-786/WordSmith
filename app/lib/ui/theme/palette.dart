import 'package:flutter/painting.dart';

import '../../engine/heat.dart';

/// Colour tokens from docs/ART_AND_AUDIO.md §2.
abstract final class Palette {
  static const forgeBlack = Color(0xFF17110E);
  static const soot = Color(0xFF241B16);
  static const ash = Color(0xFF3A2F28);
  static const iron = Color(0xFF6B6F75);
  static const steel = Color(0xFFA3ACB5);
  static const ember = Color(0xFFFF6A13);
  static const molten = Color(0xFFFFB23F);
  static const whiteHeat = Color(0xFFFFF1D0);
  static const quenchRed = Color(0xFFD9433B);
  static const verdigris = Color(0xFF3FA58E);

  static const darkLetter = Color(0xFF2A1608);

  static Color heat(Heat heat) => switch (heat) {
    Heat.ember => const Color(0xFF5A2A1C),
    Heat.dullRed => const Color(0xFF8B1E1E),
    Heat.cherryRed => const Color(0xFFC0262D),
    Heat.orange => const Color(0xFFF0701E),
    Heat.yellow => const Color(0xFFF6C343),
    Heat.whiteHeat => const Color(0xFFFFF4D6),
  };

  /// Player colours (co-op uses the first four).
  static const players = [
    Color(0xFFC8693F), // copper
    Color(0xFFE1B53B), // gold
    Color(0xFF3FA58E), // verdigris
    Color(0xFF4A78C8), // cobalt
    Color(0xFF9A6BC8), // titanium
  ];

  /// A room player's colour (0–4).
  static Color player(int color) => players[color % players.length];
}

/// Metal colours finished mold cells cool to, per campaign chapter.
class MetalStyle {
  const MetalStyle(this.base, this.highlight, this.letter);

  final Color base;
  final Color highlight;
  final Color letter;

  static const _byChapter = {
    'tin': MetalStyle(Color(0xFFB9BCB8), Color(0xFFE6E8E4), Color(0xFF2B2D2C)),
    'copper': MetalStyle(Color(0xFFC8693F), Color(0xFFF0A27A), Color(0xFF2E1408)),
    'bronze': MetalStyle(Color(0xFFA97142), Color(0xFFD9A774), Color(0xFF2A1708)),
    'iron': MetalStyle(Color(0xFF7A7E84), Color(0xFFB4B8BE), Color(0xFF16181B)),
    'steel': MetalStyle(Color(0xFF9FB3C4), Color(0xFFD7E3EE), Color(0xFF15202A)),
    'silver': MetalStyle(Color(0xFFD5D9DF), Color(0xFFFFFFFF), Color(0xFF23262B)),
    'gold': MetalStyle(Color(0xFFE1B53B), Color(0xFFFFE08A), Color(0xFF3A2805)),
    'damascus': MetalStyle(Color(0xFF8E9399), Color(0xFFCDD1D6), Color(0xFF15171A)),
    'starmetal': MetalStyle(Color(0xFF4B3F86), Color(0xFF9C8CF0), Color(0xFFF4EEFF)),
  };

  static MetalStyle forChapter(String id) => _byChapter[id] ?? _byChapter['iron']!;

  /// A metal in any colour (co-op player colours).
  factory MetalStyle.fromColor(Color c) => MetalStyle(
    c,
    Color.lerp(c, const Color(0xFFFFFFFF), 0.4)!,
    c.computeLuminance() > 0.3 ? const Color(0xFF1A1008) : const Color(0xFFFFF6E8),
  );
}

/// Chapters that have their own scene so far (docs/ART_AND_AUDIO.md §4);
/// the rest use the Forge Hall until their art lands.
const _chapterScenes = {'tin', 'copper'};

String chapterBackground(String chapterId) => _chapterScenes.contains(chapterId)
    ? 'assets/images/bg_$chapterId.webp'
    : 'assets/images/bg_hall.webp';
