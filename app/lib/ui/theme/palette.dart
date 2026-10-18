import 'package:flutter/painting.dart';

import '../../engine/heat.dart';

/// A colour scheme: the forge's own, or another the player picks in
/// Settings. Colour tokens from docs/ART_AND_AUDIO.md §2.
class PaletteScheme {
  const PaletteScheme({
    required this.id,
    required this.name,
    required this.forgeBlack,
    required this.soot,
    required this.ash,
    required this.iron,
    required this.steel,
    required this.ember,
    required this.molten,
    required this.whiteHeat,
    required this.quenchRed,
    required this.verdigris,
    required this.gold,
    required this.darkLetter,
  });

  /// Stored in Settings.
  final String id;

  /// Shown in Settings.
  final String name;

  final Color forgeBlack;
  final Color soot;
  final Color ash;
  final Color iron;
  final Color steel;
  final Color ember;
  final Color molten;
  final Color whiteHeat;
  final Color quenchRed;
  final Color verdigris;
  final Color gold;
  final Color darkLetter;

  static const forge = PaletteScheme(
    id: 'forge',
    name: 'Forge',
    forgeBlack: Color(0xFF17110E),
    soot: Color(0xFF241B16),
    ash: Color(0xFF3A2F28),
    iron: Color(0xFF6B6F75),
    steel: Color(0xFFA3ACB5),
    ember: Color(0xFFFF6A13),
    molten: Color(0xFFFFB23F),
    whiteHeat: Color(0xFFFFF1D0),
    quenchRed: Color(0xFFD9433B),
    verdigris: Color(0xFF3FA58E),
    gold: Color(0xFFE8C04A),
    darkLetter: Color(0xFF2A1608),
  );

  static const all = [forge];

  static PaletteScheme byId(String? id) => all.firstWhere((s) => s.id == id, orElse: () => forge);
}

/// The colours in use: the current [scheme]'s. Not constants, since the
/// player can change the scheme while playing.
abstract final class Palette {
  static PaletteScheme scheme = PaletteScheme.forge;

  static Color get forgeBlack => scheme.forgeBlack;
  static Color get soot => scheme.soot;
  static Color get ash => scheme.ash;
  static Color get iron => scheme.iron;
  static Color get steel => scheme.steel;
  static Color get ember => scheme.ember;
  static Color get molten => scheme.molten;
  static Color get whiteHeat => scheme.whiteHeat;
  static Color get quenchRed => scheme.quenchRed;
  static Color get verdigris => scheme.verdigris;

  /// Gilded cells and Masterwork pieces.
  static Color get gold => scheme.gold;

  static Color get darkLetter => scheme.darkLetter;

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
    // The Master Forge: white gold.
    'master': MetalStyle(Color(0xFFF0D98A), Color(0xFFFFF6D6), Color(0xFF3A2805)),
  };

  static MetalStyle forChapter(String id) => _byChapter[id] ?? _byChapter['iron']!;

  /// A metal in any colour (co-op player colours).
  factory MetalStyle.fromColor(Color c) => MetalStyle(
    c,
    Color.lerp(c, const Color(0xFFFFFFFF), 0.4)!,
    c.computeLuminance() > 0.3 ? const Color(0xFF1A1008) : const Color(0xFFFFF6E8),
  );
}

/// Chapters with their own scene (docs/ART_AND_AUDIO.md §4); anything else
/// uses the Forge Hall.
const _chapterScenes = {'tin', 'copper', 'bronze', 'iron', 'steel', 'silver', 'gold', 'damascus', 'starmetal'};

/// Moonlit and cool scenes keep most of their blue under the warm grade.
const _coolScenes = {'iron', 'steel', 'silver', 'starmetal'};

double chapterWarmth(String chapterId) => _coolScenes.contains(chapterId) ? 0.3 : 1;

bool hasChapterScene(String chapterId) => _chapterScenes.contains(chapterId);

String chapterBackground(String chapterId) =>
    _chapterScenes.contains(chapterId) ? 'assets/images/bg_$chapterId.webp' : 'assets/images/bg_hall.webp';
