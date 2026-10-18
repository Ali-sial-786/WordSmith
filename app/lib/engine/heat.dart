/// Difficulty tiers named after the colours of hot metal (DESIGN.md §5).
/// Mirrors `server/src/rules/heat.ts`.
library;

enum Heat {
  ember(1, 'Ember', 1),
  dullRed(2, 'Dull Red', 6),
  cherryRed(3, 'Cherry Red', 16),
  orange(4, 'Orange', 31),
  yellow(5, 'Yellow', 51),
  whiteHeat(6, 'White Heat', 81);

  const Heat(this.value, this.title, this.minLevel);

  /// The `heat` number stored in puzzle JSON.
  final int value;
  final String title;

  /// Lowest Smith Level that plays at this heat in multiplayer.
  final int minLevel;

  static Heat fromValue(int value) => Heat.values.firstWhere((h) => h.value == value);

  static Heat forLevel(int level) => Heat.values.lastWhere((h) => level >= h.minLevel);

  /// "Cherry Red heat", or just "White Heat".
  String get label => this == whiteHeat ? title : '$title heat';

  /// Co-op and Versus XP at this heat for a smith at [level]: ×1.0 at Ember
  /// up to ×2.0 at White Heat, plus 0.2 for each tier above the one for
  /// their level. Mirrors `heatXp` in `server/src/rules/progression.ts`.
  double xpMultiplierFor(int level) {
    final above = value - Heat.forLevel(level).value;
    return (10 + 2 * (value - 1) + 2 * (above > 0 ? above : 0)) / 10;
  }
}
