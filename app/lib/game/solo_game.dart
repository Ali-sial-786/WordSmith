import 'package:flutter/foundation.dart';

import '../engine/board.dart';
import '../engine/hints.dart';
import '../engine/puzzle.dart';
import 'providers.dart';

/// What happened after the player lifted their finger.
class WordFeedback {
  const WordFeedback(this.result, {this.smelted = false});

  final SubmitResult result;

  /// The bonus word filled the Scrap Bin, which became a Hammer Strike.
  final bool smelted;
}

/// One solo puzzle as the puzzle screen plays it: a campaign stage
/// ([SoloController]) or the Daily Commission ([DailyGame]).
abstract class SoloGame extends ChangeNotifier {
  Board get board;

  /// Tile letters (fixed for the life of the screen).
  String get letters;

  /// Ring position → tile index.
  List<int> get order;
  bool get isComplete;

  /// The chapter whose metal and background this puzzle uses.
  String get look;
  String get title;
  String get subtitle;

  WordFeedback submit(String word);

  /// Turn: reshuffle the anvil, never landing on the same arrangement.
  void turn();

  bool canUse(HintKind kind);
  RevealResult? useHammer();
  RevealResult? useChisel(CellPos cell);
  RevealResult? useSparks();

  /// Saves the play time when leaving mid-puzzle.
  void pause();

  /// Hints spent on this puzzle so far, by kind name (for the history).
  Map<String, int> get hintsUsed => const {};

  /// Time spent playing it so far (for the history).
  int get playedMs => 0;

  /// The reward for forging it: straight away in the campaign, once the
  /// server has confirmed it for the Daily Commission.
  Future<CompletionReward> finish();
}
