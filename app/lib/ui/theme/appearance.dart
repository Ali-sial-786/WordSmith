import '../../data/profile.dart';
import 'palette.dart';
import 'theme.dart';

/// Puts the player's colour scheme and fonts in place. The app calls this
/// as it builds, before any colour or font is read.
void applyAppearance(Settings s) {
  Palette.scheme = PaletteScheme.byId(s.colorScheme);
  Fonts.choice = FontChoice.byId(s.font);
}

/// Changes whenever the look does: the app rebuilds everything under it then,
/// since colours and fonts are read as widgets build.
String appearanceKey(Settings s) => '${PaletteScheme.byId(s.colorScheme).id}/${FontChoice.byId(s.font).id}';
