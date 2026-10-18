import 'package:flutter/material.dart';

import 'palette.dart';

/// A set of fonts the player can pick in Settings: one for titles, one for
/// the letters on the anvil and in the molds, and one for everything else.
/// Every set's G must stay clearly unlike its C, on the anvil and on the
/// smallest mold tiles.
class FontChoice {
  const FontChoice({
    required this.id,
    required this.name,
    required this.blurb,
    required this.display,
    required this.letters,
    required this.ui,
    this.displayWeight = 700,
    this.displaySpacing = 0.06,
    this.letterWeight = 800,
  });

  /// Stored in Settings.
  final String id;

  /// Shown in Settings, with a line about the look.
  final String name;
  final String blurb;

  final String display;
  final String letters;
  final String ui;

  /// Single-weight files ignore these and draw at their own weight.
  final double displayWeight;
  final double letterWeight;

  /// Space between title letters, in ems: roomy for capitals, tighter for
  /// mixed case.
  final double displaySpacing;

  /// The default, also for players who never picked: a slab whose G has a
  /// square spur, so it can't pass for a C.
  static const forge = FontChoice(
    id: 'forge',
    name: 'Forge',
    blurb: 'Sturdy slab letters',
    display: 'VollkornSC',
    letters: 'Arvo',
    ui: 'NunitoSans',
    displaySpacing: 0.03,
    letterWeight: 700,
  );

  /// The game's first look.
  static const classic = FontChoice(
    id: 'classic',
    name: 'Classic',
    blurb: 'Roman capitals',
    display: 'Cinzel',
    letters: 'RobotoSlab',
    ui: 'NunitoSans',
  );

  static const clear = FontChoice(
    id: 'clear',
    name: 'Clear',
    blurb: 'Made for easy reading',
    display: 'AtkinsonHyperlegibleNext',
    letters: 'AtkinsonHyperlegibleNext',
    ui: 'AtkinsonHyperlegibleNext',
    displayWeight: 800,
    displaySpacing: 0.01,
  );

  static const guild = FontChoice(
    id: 'guild',
    name: 'Guild',
    blurb: 'Old guild lettering',
    display: 'Texturina',
    letters: 'Texturina',
    ui: 'NunitoSans',
    displaySpacing: 0.02,
    letterWeight: 900,
  );

  static const foundry = FontChoice(
    id: 'foundry',
    name: 'Foundry',
    blurb: 'Heavy slab throughout',
    display: 'Arvo',
    letters: 'Arvo',
    ui: 'NunitoSans',
    displaySpacing: 0.02,
    letterWeight: 700,
  );

  static const all = [forge, classic, clear, guild, foundry];

  static FontChoice byId(String? id) => all.firstWhere((f) => f.id == id, orElse: () => forge);
}

/// The font families in use: the current [choice]'s. Not constants, since
/// the player can change fonts while playing.
abstract final class Fonts {
  static FontChoice choice = FontChoice.forge;

  static String get display => choice.display;
  static String get letters => choice.letters;
  static String get ui => choice.ui;
}

/// Variable fonts need their weight axis set explicitly.
List<FontVariation> weight(double w) => [FontVariation('wght', w)];

FontWeight _fontWeight(double w) => FontWeight.values[(w ~/ 100) - 1];

/// Title lettering, in the player's fonts or another [font] (the picker's
/// samples).
TextStyle displayStyle(double size, {Color? color, FontChoice? font}) {
  final f = font ?? Fonts.choice;
  return TextStyle(
    fontFamily: f.display,
    fontSize: size,
    fontWeight: _fontWeight(f.displayWeight),
    fontVariations: weight(f.displayWeight),
    color: color ?? Palette.whiteHeat,
    letterSpacing: size * f.displaySpacing,
  );
}

/// The letters on the anvil and in the molds.
TextStyle letterStyle(double size, {Color? color, FontChoice? font}) {
  final f = font ?? Fonts.choice;
  return TextStyle(
    fontFamily: f.letters,
    fontSize: size,
    fontWeight: _fontWeight(f.letterWeight),
    fontVariations: weight(f.letterWeight),
    color: color ?? Palette.whiteHeat,
    height: 1,
  );
}

ThemeData buildTheme() {
  final scheme = ColorScheme.dark(
    primary: Palette.ember,
    onPrimary: Palette.forgeBlack,
    secondary: Palette.molten,
    onSecondary: Palette.forgeBlack,
    surface: Palette.soot,
    onSurface: Palette.whiteHeat,
    error: Palette.quenchRed,
    outline: Palette.ash,
  );
  TextStyle ui(double size, double w, [Color? color]) => TextStyle(
    fontFamily: Fonts.ui,
    fontSize: size,
    fontWeight: FontWeight.values[(w ~/ 100) - 1],
    fontVariations: weight(w),
    color: color,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.forgeBlack,
    fontFamily: Fonts.ui,
    textTheme: TextTheme(
      displaySmall: displayStyle(30),
      headlineMedium: displayStyle(24),
      headlineSmall: displayStyle(20),
      titleLarge: ui(20, 800),
      titleMedium: ui(16, 700),
      titleSmall: ui(14, 700),
      bodyLarge: ui(16, 500),
      bodyMedium: ui(14, 500),
      bodySmall: ui(12, 500, Palette.steel),
      labelLarge: ui(15, 800),
      labelMedium: ui(13, 700),
      labelSmall: ui(11, 700, Palette.steel),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: Palette.ember,
      thumbColor: Palette.molten,
      inactiveTrackColor: Palette.ash,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Palette.molten : Palette.steel,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Palette.ember : Palette.ash,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Palette.soot,
      contentTextStyle: TextStyle(color: Palette.whiteHeat),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
