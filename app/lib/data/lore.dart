import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A page of Smith's Lore: one forge fact, unlocked by a Daily Commission.
class LorePage {
  const LorePage({required this.id, required this.title, required this.text, required this.topic});

  factory LorePage.fromJson(Map<String, dynamic> j) => LorePage(
    id: (j['id'] as num).toInt(),
    title: j['title'] as String? ?? '',
    text: j['text'] as String? ?? '',
    topic: j['topic'] as String? ?? 'craft',
  );

  final int id;
  final String title;
  final String text;

  /// metals, history, tools, words, legends or craft.
  final String topic;

  String get topicLabel => switch (topic) {
    'metals' => 'Metals',
    'history' => 'History',
    'tools' => 'Tools',
    'words' => 'Words',
    'legends' => 'Legends',
    _ => 'Craft',
  };
}

/// Every page in order (assets/lore/lore.json); empty if it can't be read.
final loreProvider = FutureProvider<List<LorePage>>((ref) async {
  try {
    final raw = jsonDecode(await rootBundle.loadString('assets/lore/lore.json')) as Map;
    return [for (final p in (raw['pages'] as List).cast<Map<String, dynamic>>()) LorePage.fromJson(p)];
  } on Object {
    return const [];
  }
}, retry: (_, _) => null);
