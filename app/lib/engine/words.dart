/// Word helpers shared by every mode. Mirrors `server/src/rules/words.ts`.
library;

const int minWordLength = 3;

/// Uppercases and strips everything that is not A–Z.
String normalizeWord(String raw) =>
    raw.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');

/// Whether [word] can be built from the anvil [letters], using each tile at
/// most as many times as it appears.
bool canBeMadeFrom(String word, String letters) {
  final counts = <int, int>{};
  for (final c in letters.codeUnits) {
    counts[c] = (counts[c] ?? 0) + 1;
  }
  for (final c in word.codeUnits) {
    final left = (counts[c] ?? 0) - 1;
    if (left < 0) return false;
    counts[c] = left;
  }
  return true;
}
