import 'package:wordsmith/engine/puzzle.dart';

/// The example puzzle from shared/puzzle-format.md:
///
///     T E A R
///     . A . A
///     . T . T
///     . . . E
Map<String, dynamic> tearJson() => {
  'id': 'c-0001',
  'letters': 'RTAE',
  'heat': 1,
  'cols': 4,
  'rows': 4,
  'words': [
    {'w': 'TEAR', 'x': 0, 'y': 0, 'd': 'a'},
    {'w': 'EAT', 'x': 1, 'y': 0, 'd': 'd'},
    {'w': 'RATE', 'x': 3, 'y': 0, 'd': 'd'},
  ],
  'bonus': ['ARE', 'ART', 'ATE', 'EAR', 'ERA', 'RAT', 'TAR', 'TEA'],
};

Puzzle tearPuzzle() => Puzzle.fromJson(tearJson());
