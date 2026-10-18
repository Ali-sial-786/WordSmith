import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One sense of a word: its part of speech and a short definition.
class Sense {
  const Sense(this.pos, this.gloss);

  /// "n", "v", "a" or "r". Online definitions can also have another part
  /// of speech spelled out ("proper noun", "interjection"), or "".
  final String pos;
  final String gloss;

  String get posLabel => switch (pos) {
    'n' => 'noun',
    'v' => 'verb',
    'a' => 'adjective',
    'r' => 'adverb',
    _ when pos.length > 1 => pos,
    _ => '',
  };
}

/// What a word means. [base] is set when the word is a form of another
/// (FORGED → FORGE), whose senses these are.
class Meaning {
  const Meaning({
    required this.word,
    required this.senses,
    this.base,
    this.source,
    this.sourceUrl,
    this.license,
    this.licenseUrl,
  });

  final String word;
  final String? base;
  final List<Sense> senses;

  /// Which online dictionary these senses came from (the server's
  /// `GET /v1/define`: "wiktionary" or "dictionaryapi.dev"); null for the
  /// offline lexicon's.
  final String? source;

  /// The Wiktionary entry online senses came from, and its licence: CC BY-SA
  /// asks for both to be shown with the text. A server from before 0.7 sends
  /// none, so these fall back to the entry for [word] and CC BY-SA 4.0.
  final String? sourceUrl;
  final String? license;
  final String? licenseUrl;

  String get sourcePage => sourceUrl ?? 'https://en.wiktionary.org/wiki/${Uri.encodeComponent(word.toLowerCase())}';
  String get licenseName => license ?? 'CC BY-SA 4.0';
  String get licensePage => licenseUrl ?? 'https://creativecommons.org/licenses/by-sa/4.0/';
}

/// The offline dictionary (tools/dictgen, from WordNet). It's split into one
/// file per first letter so a lookup only loads a small part of it.
class Lexicon {
  Lexicon(this._bundle);

  final AssetBundle _bundle;
  final Map<String, Future<_Shard?>> _shards = {};

  /// The meaning of [word] (any case), or null if the dictionary has none.
  Future<Meaning?> lookup(String word) async {
    final key = word.toLowerCase();
    if (key.isEmpty) return null;
    final shard = await _shard(key[0]);
    if (shard == null) return null;
    final senses = shard.entries[key];
    if (senses != null) return Meaning(word: key.toUpperCase(), senses: senses);
    final base = shard.forms[key];
    if (base == null || base.isEmpty) return null;
    final baseShard = await _shard(base[0]);
    final baseSenses = baseShard?.entries[base];
    if (baseSenses == null) return null;
    return Meaning(word: key.toUpperCase(), base: base.toUpperCase(), senses: baseSenses);
  }

  Future<_Shard?> _shard(String letter) {
    if (!RegExp('^[a-z]\$').hasMatch(letter)) return Future.value();
    return _shards[letter] ??= _load(letter);
  }

  Future<_Shard?> _load(String letter) async {
    try {
      final data = await _bundle.load('assets/dict/$letter.json.gz');
      return await compute(_decode, data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    } on Object catch (e) {
      debugPrint('lexicon $letter: $e');
      _shards.remove(letter);
      return null;
    }
  }
}

class _Shard {
  const _Shard(this.entries, this.forms);

  final Map<String, List<Sense>> entries;
  final Map<String, String> forms;
}

_Shard _decode(Uint8List gz) {
  final json = jsonDecode(utf8.decode(const GZipDecoder().decodeBytes(gz))) as Map<String, dynamic>;
  return _Shard({
    for (final e in (json['entries'] as Map<String, dynamic>).entries)
      e.key: [for (final s in (e.value as List).cast<List>()) Sense(s[0] as String, s[1] as String)],
  }, (json['forms'] as Map<String, dynamic>).cast<String, String>());
}

final lexiconProvider = Provider<Lexicon>((_) => Lexicon(rootBundle));

/// Meanings, cached per word.
final meaningProvider = FutureProvider.family<Meaning?, String>(
  (ref, word) => ref.watch(lexiconProvider).lookup(word),
  retry: (_, _) => null,
);
