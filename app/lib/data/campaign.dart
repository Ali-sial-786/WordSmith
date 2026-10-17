import 'dart:convert';

import 'package:flutter/services.dart';

import '../engine/puzzle.dart';

const String campaignAsset = 'assets/campaign/campaign.json';

class Chapter {
  const Chapter({
    required this.id,
    required this.name,
    required this.first,
    required this.count,
  });

  final String id;
  final String name;

  /// First campaign stage in this chapter (1-based).
  final int first;
  final int count;

  int get last => first + count - 1;

  bool contains(int stage) => stage >= first && stage <= last;
}

/// The bundled solo campaign (format: shared/puzzle-format.md).
class Campaign {
  Campaign._(this.chapters, this._raw);

  factory Campaign.fromJson(Map<String, dynamic> json) {
    final chapters = [
      for (final c in (json['chapters'] as List).cast<Map<String, dynamic>>())
        Chapter(
          id: c['id'] as String,
          name: c['name'] as String,
          first: c['first'] as int,
          count: c['count'] as int,
        ),
    ];
    return Campaign._(
      List.unmodifiable(chapters),
      (json['puzzles'] as List).cast<Map<String, dynamic>>(),
    );
  }

  static Future<Campaign> load([AssetBundle? bundle]) async {
    final text = await (bundle ?? rootBundle).loadString(campaignAsset);
    return Campaign.fromJson(jsonDecode(text) as Map<String, dynamic>);
  }

  final List<Chapter> chapters;
  final List<Map<String, dynamic>> _raw;
  final Map<int, Puzzle> _parsed = {};

  /// Stages in the campaign proper.
  int get stageCount => _raw.length;

  /// The last stage there is: the Master Forge goes round nine more times
  /// (shared/master-forge.md).
  int get maxStage => stageCount * 10;

  /// Whether [stage] is past the campaign proper.
  bool isMaster(int stage) => stage > stageCount;

  /// The campaign stage whose puzzle [stage] plays.
  int baseStage(int stage) => isMaster(stage) ? (stage - stageCount - 1) % stageCount + 1 : stage;

  /// Puzzle for [stage] (1-based), parsed on first use.
  Puzzle puzzle(int stage) {
    final base = baseStage(stage);
    return _parsed[base] ??= Puzzle.fromJson(_raw[base - 1]);
  }

  /// The tenth chapter, open once the campaign is done.
  late final Chapter master = Chapter(
    id: 'master',
    name: 'Master Forge',
    first: stageCount + 1,
    count: maxStage - stageCount,
  );

  Chapter chapterFor(int stage) =>
      isMaster(stage) ? master : chapters.firstWhere((c) => c.contains(stage), orElse: () => chapters.last);

  int chapterIndex(Chapter chapter) => chapters.indexOf(chapter);
}
