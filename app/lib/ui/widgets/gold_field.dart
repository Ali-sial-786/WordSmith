import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/palette.dart';
import '../theme/theme.dart';

/// A box for typing a name that clearly reads as one: gold text on a dark
/// fill, inside a gold border that brightens while it has focus. Its
/// decoration is spelled out here rather than taken from the theme, so it
/// looks the same whatever the theme's own input style is.
class GoldTextField extends StatelessWidget {
  const GoldTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.label,
    this.helper,
    this.error,
    this.icon,
    this.maxLength,
    this.enabled = true,
    this.autofocus = false,
    this.inputFormatters,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;

  /// Shown inside the empty box, e.g. "Friend's username".
  final String hint;
  final String? label;
  final String? helper;
  final String? error;
  final IconData? icon;
  final int? maxLength;
  final bool enabled;
  final bool autofocus;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// The gold border's colour while focused: the gold lifted towards white heat.
  static Color get focusedGold => Color.lerp(Palette.gold, Palette.whiteHeat, 0.4)!;

  static OutlineInputBorder _border(Color color, double width) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: color, width: width),
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final gold = Palette.gold;
    return TextField(
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      maxLength: maxLength,
      inputFormatters: inputFormatters,
      textInputAction: textInputAction,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      cursorColor: Palette.molten,
      style: TextStyle(
        fontFamily: Fonts.ui,
        fontSize: 17,
        fontWeight: FontWeight.w700,
        fontVariations: weight(700),
        color: enabled ? gold : gold.withValues(alpha: 0.5),
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: gold.withValues(alpha: 0.55), fontWeight: FontWeight.w500),
        labelText: label,
        labelStyle: TextStyle(color: gold.withValues(alpha: 0.85)),
        floatingLabelStyle: TextStyle(color: focusedGold, fontWeight: FontWeight.w700),
        helperText: helper,
        helperStyle: text.bodySmall,
        helperMaxLines: 3,
        errorText: error,
        errorStyle: TextStyle(color: Palette.quenchRed),
        errorMaxLines: 3,
        counterStyle: text.labelSmall,
        prefixIcon: icon == null ? null : Icon(icon, color: gold),
        filled: true,
        fillColor: Palette.forgeBlack.withValues(alpha: 0.7),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        enabledBorder: _border(gold.withValues(alpha: 0.8), 1.6),
        focusedBorder: _border(focusedGold, 2.4),
        disabledBorder: _border(gold.withValues(alpha: 0.3), 1.2),
        errorBorder: _border(Palette.quenchRed, 1.6),
        focusedErrorBorder: _border(Palette.quenchRed, 2.4),
      ),
    );
  }
}
