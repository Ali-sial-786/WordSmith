/// Hint items: what they are and when they unlock (DESIGN.md §3).
library;

enum HintKind {
  hammer('Hammer Strike', 1),
  chisel('Chisel', 5),
  sparks('Spark Shower', 12);

  const HintKind(this.title, this.unlockLevel);

  final String title;

  /// Smith Level at which this hint type becomes available.
  final int unlockLevel;

  bool unlockedAt(int level) => level >= unlockLevel;

  static HintKind byName(String name) =>
      HintKind.values.firstWhere((k) => k.name == name);
}

/// Letters revealed by one Spark Shower.
const int sparkShowerLetters = 5;

/// Bonus words needed to smelt the Scrap Bin into a Hammer Strike.
const int scrapBinCapacity = 10;

/// Hammer Strikes every new smith starts with.
const int startingHammers = 3;
