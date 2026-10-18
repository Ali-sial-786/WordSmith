import 'package:flutter/material.dart';

import 'palette.dart';

/// A set of fonts the player can pick in Settings: one for titles, one for
/// the letters on the anvil and in the molds, and one for everything else.
class FontChoice {
  const FontChoice({
    required this.id,
    required this.name,
    required this.display,
    required this.letters,
    required this.ui,
  });

  /// Stored in Settings.
  final String id;

  /// Shown in Settings.
  final String name;

  final String display;
  final String letters;
  final String ui;

  static const forge = FontChoice(
    id: 'forge',
    name: 'Forge',
    display: 'Cinzel',
    letters: 'RobotoSlab',
    ui: 'NunitoSans',
  );

  static const all = [forge];

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

TextStyle displayStyle(double size, {Color? color}) => TextStyle(
  fontFamily: Fonts.display,
  fontSize: size,
  fontWeight: FontWeight.w700,
  fontVariations: weight(700),
  color: color ?? Palette.whiteHeat,
  letterSpacing: size * 0.06,
);

TextStyle letterStyle(double size, {Color? color}) => TextStyle(
  fontFamily: Fonts.letters,
  fontSize: size,
  fontWeight: FontWeight.w800,
  fontVariations: weight(800),
  color: color ?? Palette.whiteHeat,
  height: 1,
);

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
