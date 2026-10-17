import 'package:flutter/material.dart';

import 'palette.dart';

abstract final class Fonts {
  static const display = 'Cinzel';
  static const letters = 'RobotoSlab';
  static const ui = 'NunitoSans';
}

/// Variable fonts need their weight axis set explicitly.
List<FontVariation> weight(double w) => [FontVariation('wght', w)];

TextStyle displayStyle(double size, {Color color = Palette.whiteHeat}) =>
    TextStyle(
      fontFamily: Fonts.display,
      fontSize: size,
      fontWeight: FontWeight.w700,
      fontVariations: weight(700),
      color: color,
      letterSpacing: size * 0.06,
    );

TextStyle letterStyle(double size, {Color color = Palette.whiteHeat}) =>
    TextStyle(
      fontFamily: Fonts.letters,
      fontSize: size,
      fontWeight: FontWeight.w800,
      fontVariations: weight(800),
      color: color,
      height: 1,
    );

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
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
    sliderTheme: const SliderThemeData(
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
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Palette.soot,
      contentTextStyle: TextStyle(color: Palette.whiteHeat),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
