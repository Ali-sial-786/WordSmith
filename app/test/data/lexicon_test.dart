import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/data/lexicon.dart';

/// Serves made-up dictionary shards.
class _Shards extends CachingAssetBundle {
  _Shards(this.shards);

  final Map<String, Map<String, Object>> shards;
  final loads = <String>[];

  @override
  Future<ByteData> load(String key) async {
    loads.add(key);
    final letter = RegExp(r'assets/dict/(\w)\.json\.gz').firstMatch(key)?.group(1);
    final shard = shards[letter];
    if (shard == null) throw StateError('missing $key');
    final gz = const GZipEncoder().encodeBytes(utf8.encode(jsonEncode({'v': 1, ...shard})));
    return ByteData.sublistView(Uint8List.fromList(gz));
  }
}

void main() {
  final bundle = _Shards({
    'f': {
      'entries': {
        'forge': [
          ['v', 'create by hammering'],
          ['n', 'furnace where metal is heated'],
        ],
      },
      'forms': {'forged': 'forge'},
    },
    'g': {
      'entries': {
        'go': [
          ['v', 'change location; move'],
        ],
      },
      'forms': <String, String>{},
    },
    'w': {'entries': <String, Object>{}, 'forms': {'went': 'go'}},
  });

  test('looks up words, forms and missing words', () async {
    final lexicon = Lexicon(bundle);
    final forge = (await lexicon.lookup('FORGE'))!;
    expect(forge.word, 'FORGE');
    expect(forge.base, isNull);
    expect(forge.senses.map((s) => (s.posLabel, s.gloss)), [
      ('verb', 'create by hammering'),
      ('noun', 'furnace where metal is heated'),
    ]);

    final forged = (await lexicon.lookup('forged'))!;
    expect((forged.word, forged.base, forged.senses.length), ('FORGED', 'FORGE', 2));

    final went = (await lexicon.lookup('WENT'))!;
    expect((went.base, went.senses.single.gloss), ('GO', 'change location; move'));

    expect(await lexicon.lookup('FORGERY'), isNull);
    expect(await lexicon.lookup('QUIXOTIC'), isNull, reason: 'no q shard');
    expect(await lexicon.lookup(''), isNull);
    expect(bundle.loads.where((k) => k.endsWith('f.json.gz')).length, 1, reason: 'shards are cached');
  });
}
