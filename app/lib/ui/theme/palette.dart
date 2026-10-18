import 'dart:ui' show Brightness;

import 'package:flutter/painting.dart';

import '../../engine/heat.dart';

/// A colour scheme: the forge's own, or another the player picks in
/// Settings. Colour tokens from docs/ART_AND_AUDIO.md §2.
class PaletteScheme {
  const PaletteScheme({
    required this.id,
    required this.name,
    this.brightness = Brightness.dark,
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
    required this.onAccent,
    required this.panel,
    required this.rim,
    required this.plate,
    this.scene,
    this.asRendered = false,
  });

  /// Stored in Settings.
  final String id;

  /// Shown in Settings.
  final String name;

  /// Light schemes have dark text on pale panels and scenes.
  final Brightness brightness;

  /// The background.
  final Color forgeBlack;

  /// Dialogs, sheets and painted cards.
  final Color soot;

  /// Borders and empty tracks.
  final Color ash;
  final Color iron;

  /// Secondary text and icons.
  final Color steel;

  /// The main accent: buttons, bars, the selected thing.
  final Color ember;

  /// Highlighted text and the second accent.
  final Color molten;

  /// Text and letters.
  final Color whiteHeat;
  final Color quenchRed;
  final Color verdigris;
  final Color gold;

  /// Letters on fire-hot tiles and cells, which glow orange in every scheme.
  final Color darkLetter;

  /// Text and icons on accent buttons ([plate]).
  final Color onAccent;

  /// The face of framed cards and plates.
  final Color panel;

  /// The metal of their frames (bronze in the forge).
  final Color rim;

  /// The face of accent buttons, bottom to top.
  final (Color, Color) plate;

  /// What the scene pictures are tinted towards; null keeps the forge's own
  /// warm firelight.
  final Color? scene;

  /// Uses the UI kit's renders as they are (the forge, which they were made for).
  final bool asRendered;

  bool get isLight => brightness == Brightness.light;

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
    onAccent: Color(0xFF2A1608),
    panel: Color(0xFF201B17),
    rim: Color(0xFF8C6B47),
    plate: (Color(0xFFFF6A13), Color(0xFFFFC45E)),
    asRendered: true,
  );

  /// Ivory and gold: the light scheme.
  static const gilded = PaletteScheme(
    id: 'gilded',
    name: 'Gilded',
    brightness: Brightness.light,
    forgeBlack: Color(0xFFF3EAD6),
    soot: Color(0xFFFFFAEE),
    ash: Color(0xFFC9B48A),
    iron: Color(0xFF9E8C70),
    steel: Color(0xFF6A5A45),
    ember: Color(0xFFA06A00),
    molten: Color(0xFF8A5A00),
    whiteHeat: Color(0xFF2B1F12),
    quenchRed: Color(0xFFB02A20),
    verdigris: Color(0xFF1D7560),
    gold: Color(0xFF8C6A0E),
    darkLetter: Color(0xFF2A1608),
    onAccent: Color(0xFF3A2805),
    panel: Color(0xFFFBF4E4),
    rim: Color(0xFFC79A3A),
    plate: (Color(0xFFD9A931), Color(0xFFFFE9A8)),
    scene: Color(0xFFE2C48E),
  );

  /// Cool blue-grey steel, silver frames and tempered-blue accents.
  static const steelBlue = PaletteScheme(
    id: 'steel',
    name: 'Steel',
    forgeBlack: Color(0xFF0F151B),
    soot: Color(0xFF19222C),
    ash: Color(0xFF2C3948),
    iron: Color(0xFF67768A),
    steel: Color(0xFF9CAEC2),
    ember: Color(0xFF5FA8E8),
    molten: Color(0xFFAED3F5),
    whiteHeat: Color(0xFFEEF4FA),
    quenchRed: Color(0xFFE8574E),
    verdigris: Color(0xFF45BC9E),
    gold: Color(0xFFE6C65E),
    darkLetter: Color(0xFF2A1608),
    onAccent: Color(0xFF0B1624),
    panel: Color(0xFF18202A),
    rim: Color(0xFFA7B3C0),
    plate: (Color(0xFF5E9BD3), Color(0xFFDCEBF8)),
    scene: Color(0xFF8DB2D9),
  );

  /// Green-blue patina with copper.
  static const verdigrisCopper = PaletteScheme(
    id: 'verdigris',
    name: 'Verdigris',
    forgeBlack: Color(0xFF0A1A19),
    soot: Color(0xFF112826),
    ash: Color(0xFF22413D),
    iron: Color(0xFF5D7E78),
    steel: Color(0xFF93B8B0),
    ember: Color(0xFFDB7A42),
    molten: Color(0xFFF5AA72),
    whiteHeat: Color(0xFFF2F6EE),
    quenchRed: Color(0xFFEE5A4F),
    verdigris: Color(0xFF5CD6AE),
    gold: Color(0xFFE8C451),
    darkLetter: Color(0xFF2A1608),
    onAccent: Color(0xFF2A1206),
    panel: Color(0xFF102624),
    rim: Color(0xFFB8774A),
    plate: (Color(0xFFC9673A), Color(0xFFF7C29A)),
    scene: Color(0xFF6CC2AE),
  );

  /// Deep red with brass.
  static const crimson = PaletteScheme(
    id: 'crimson',
    name: 'Crimson',
    forgeBlack: Color(0xFF1A0A0C),
    soot: Color(0xFF2B1215),
    ash: Color(0xFF4C2328),
    iron: Color(0xFF80595D),
    steel: Color(0xFFC4A3A5),
    ember: Color(0xFFD9AA48),
    molten: Color(0xFFF4D27C),
    whiteHeat: Color(0xFFFFF1E8),
    quenchRed: Color(0xFFFF6F5E),
    verdigris: Color(0xFF52B994),
    gold: Color(0xFFF2CF5C),
    darkLetter: Color(0xFF2A1608),
    onAccent: Color(0xFF2A1A04),
    panel: Color(0xFF2A1114),
    rim: Color(0xFFB8913F),
    plate: (Color(0xFFC4922E), Color(0xFFF8E2A0)),
    scene: Color(0xFFD9686A),
  );

  /// Indigo night and violet starmetal.
  static const starmetal = PaletteScheme(
    id: 'starmetal',
    name: 'Starmetal',
    forgeBlack: Color(0xFF0E0B1F),
    soot: Color(0xFF1A1631),
    ash: Color(0xFF2F2952),
    iron: Color(0xFF6B6394),
    steel: Color(0xFFA9A3CF),
    ember: Color(0xFF9A88F5),
    molten: Color(0xFFCDC2FF),
    whiteHeat: Color(0xFFF4F0FF),
    quenchRed: Color(0xFFF25A6E),
    verdigris: Color(0xFF4FCBA8),
    gold: Color(0xFFF0D27A),
    darkLetter: Color(0xFF2A1608),
    onAccent: Color(0xFF130D30),
    panel: Color(0xFF191430),
    rim: Color(0xFFA99FD6),
    plate: (Color(0xFF8C78EE), Color(0xFFE4DDFF)),
    scene: Color(0xFF8F86E6),
  );

  static const all = [forge, gilded, steelBlue, verdigrisCopper, crimson, starmetal];

  static PaletteScheme byId(String? id) => all.firstWhere((s) => s.id == id, orElse: () => forge);
}

/// The colours in use: the current [scheme]'s. Not constants, since the
/// player can change the scheme while playing.
abstract final class Palette {
  static PaletteScheme scheme = PaletteScheme.forge;

  static bool get isLight => scheme.isLight;

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
  static Color get onAccent => scheme.onAccent;
  static Color get panel => scheme.panel;
  static Color get rim => scheme.rim;

  /// A thin line of the frames' metal around painted cards and bars.
  static Color get edge =>
      scheme.asRendered ? const Color(0xFF5C4733) : Color.lerp(scheme.rim, scheme.forgeBlack, 0.35)!;

  /// A painted round of the frames' iron, lit from the top left (avatar
  /// badges, and round buttons whose render is missing).
  static List<Color> get roundFace => scheme.asRendered
      ? const [Color(0xFF5A524B), Color(0xFF34302C), Color(0xFF1E1B19)]
      : [
          Color.lerp(scheme.panel, scheme.rim, 0.3)!,
          scheme.panel,
          Color.lerp(scheme.panel, const Color(0xFF000000), 0.2)!,
        ];

  /// Top to bottom shading of a painted card (Versus molds and round summaries).
  static List<Color> get cardShade => scheme.asRendered
      ? [const Color(0xFF2C221C), scheme.soot, const Color(0xFF1B1411)]
      : [
          Color.lerp(scheme.soot, scheme.rim, 0.1)!,
          scheme.soot,
          Color.lerp(scheme.soot, const Color(0xFF000000), scheme.isLight ? 0.06 : 0.25)!,
        ];

  /// An empty cell in a small painted mold: the top and bottom of its
  /// hollow, and its edge.
  static ({Color top, Color bottom, Color edge}) get recess => scheme.asRendered
      ? (top: const Color(0xFF0F0B09), bottom: const Color(0xFF221A15), edge: const Color(0xFF3E322A))
      : scheme.isLight
      ? (top: const Color(0xFFCFC6B6), bottom: const Color(0xFFE9E2D4), edge: const Color(0xFFB9AD98))
      : (
          top: Color.lerp(scheme.forgeBlack, const Color(0xFF000000), 0.4)!,
          bottom: Color.lerp(scheme.forgeBlack, scheme.soot, 0.6)!,
          edge: Color.lerp(scheme.ash, scheme.soot, 0.2)!,
        );

  /// [c] (a player's colour, say) as text on the background: darkened
  /// towards the ink in a light scheme, as it is in a dark one.
  static Color legible(Color c) => scheme.isLight ? Color.lerp(c, scheme.whiteHeat, 0.45)! : c;

  /// The bright end of glowing bars (XP).
  static Color get glint => scheme.isLight ? scheme.plate.$1 : scheme.whiteHeat;

  /// Fire, sparks and glowing metal, which are fire-coloured in every scheme.
  static const fire = (white: Color(0xFFFFF1D0), molten: Color(0xFFFFB23F), ember: Color(0xFFFF6A13));

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

/// Colour matrices (for [ColorFilter.matrix]) that repaint the renders, which
/// were made for the forge, in the current scheme's colours.
abstract final class SchemeFilters {
  static const identity = <double>[1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];

  /// Paints a picture in [dark] → [light] by its brightness: luminance [lo]
  /// becomes [dark] and [hi] becomes [light], and the shading stays.
  static List<double> duotone(Color dark, Color light, {double lo = 0, double hi = 1}) {
    List<double> row(double d, double l) {
      final k = (l - d) / (hi - lo);
      return [k * 0.2126, k * 0.7152, k * 0.0722, 0, 255 * (d - lo * k)];
    }

    return [...row(dark.r, light.r), ...row(dark.g, light.g), ...row(dark.b, light.b), 0, 0, 0, 1, 0];
  }

  /// [t] of the way from matrix [a] to [b].
  static List<double> mix(List<double> a, List<double> b, double t) => [
    for (var i = 0; i < 20; i++) a[i] + (b[i] - a[i]) * t,
  ];

  /// Polished metal in [mid]: luminance [at] becomes [mid], black stays near
  /// black and highlights go past it towards white.
  static List<double> metal(Color mid, {double at = 0.45}) {
    List<double> row(double c) {
      final k = c * 0.85 / at;
      return [k * 0.2126, k * 0.7152, k * 0.0722, 0, 255 * 0.15 * c];
    }

    return [...row(mid.r), ...row(mid.g), ...row(mid.b), 0, 0, 0, 1, 0];
  }

  /// The frame of a UI kit piece; [gold] for the bright-rimmed ones.
  static List<double> rim({bool gold = false}) {
    final s = Palette.scheme;
    return metal(gold ? Color.lerp(s.rim, s.isLight ? s.plate.$1 : s.gold, 0.5)! : s.rim);
  }

  /// The face of a UI kit piece: dark iron as [PaletteScheme.panel], a
  /// warmer one for [warm] (rewards waiting), molten as [PaletteScheme.plate]
  /// for [hot].
  static List<double> face({bool hot = false, bool warm = false}) {
    final s = Palette.scheme;
    if (hot) return duotone(s.plate.$1, s.plate.$2, lo: 0.45, hi: 0.85);
    final base = warm ? Color.lerp(s.panel, s.gold, s.isLight ? 0.14 : 0.1)! : s.panel;
    final sheen = s.isLight ? const Color(0xFFFFFFFF) : Color.lerp(base, s.rim, 0.3)!;
    return duotone(base, sheen, lo: 0.11, hi: 0.4);
  }

  /// The scene pictures, tinted towards [PaletteScheme.scene] (null for the
  /// forge's own, which [ForgeBackground] grades itself).
  static List<double>? scene() {
    final s = Palette.scheme;
    final tint = s.scene;
    if (tint == null) return null;
    // A light scheme lifts the shadows too: a sepia print under the wash.
    if (s.isLight) return duotone(Color.lerp(tint, const Color(0xFF5A4630), 0.55)!, const Color(0xFFFFFBF0), hi: 0.6);
    return mix(identity, metal(tint, at: 0.6), 0.8);
  }

  /// A scene picture behind a card: tinted like [scene], then [dim] of the
  /// way to the background colour (dark or pale), so the card's text reads.
  static List<double> dimmed(double dim) {
    final bg = Palette.forgeBlack;
    final m = scene() ?? identity;
    return [
      for (final (row, c) in [(0, bg.r), (1, bg.g), (2, bg.b)]) ...[
        for (var i = 0; i < 4; i++) m[row * 5 + i] * (1 - dim),
        m[row * 5 + 4] * (1 - dim) + 255 * dim * c,
      ],
      0, 0, 0, 1, 0, //
    ];
  }

  /// The hero objects (anvil, letter tiles, mold cells): the forge's warm iron
  /// takes on a little of the scheme's colour, or turns to pale polished steel
  /// in a light scheme. Null for the forge.
  static List<double>? iron() {
    final s = Palette.scheme;
    if (s.asRendered) return null;
    if (s.isLight) return duotone(const Color(0xFF9C9182), const Color(0xFFFFFCF4), lo: 0.08, hi: 0.4);
    final tint = Color.lerp(s.scene ?? s.rim, const Color(0xFF9A9A9A), 0.45)!;
    return mix(identity, duotone(const Color(0xFF000000), tint, hi: 0.6), 0.7);
  }

  /// The forge fire along the bottom of a scene, burning in the accent's
  /// colour with a white-hot core. Null for the forge.
  static List<double>? fire() {
    final s = Palette.scheme;
    if (s.asRendered) return null;
    return metal(s.isLight ? s.plate.$1 : s.ember, at: 0.4);
  }
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
