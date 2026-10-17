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

  int get stageCount => _raw.length;

  /// Puzzle for campaign [stage] (1-based), parsed on first use.
  Puzzle puzzle(int stage) =>
      _parsed[stage] ??= Puzzle.fromJson(_raw[stage - 1]);

  Chapter chapterFor(int stage) => chapters.firstWhere(
    (c) => c.contains(stage),
    orElse: () => chapters.last,
  );

  int chapterIndex(Chapter chapter) => chapters.indexOf(chapter);
}
