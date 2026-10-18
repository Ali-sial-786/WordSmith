import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../data/lexicon.dart';
import '../../game/account.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import 'game_icon.dart';

/// Says a word aloud with the phone's text-to-speech.
class Speaker {
  FlutterTts? _tts;

  Future<void> say(String word) async {
    try {
      final tts = _tts ??= FlutterTts();
      await tts.setLanguage('en-US');
      await tts.setSpeechRate(0.42);
      await tts.stop();
      await tts.speak(word.toLowerCase());
    } on Object catch (e) {
      debugPrint('speak: $e');
    }
  }
}

final speakerProvider = Provider<Speaker>((_) => Speaker());

/// Online definitions ([ApiClient.define]) for words the lexicon lacks, such
/// as names and rarer words. Null without a server, or when no dictionary
/// has the word. Kept for the session, except failed lookups (offline, the
/// server unreachable), which are dropped once nothing shows them, so the
/// next look tries again.
final onlineMeaningProvider = FutureProvider.autoDispose.family<Meaning?, String>((ref, word) async {
  final api = ref.watch(apiClientProvider);
  if (api == null) return null;
  final keep = ref.keepAlive();
  try {
    return await api.define(word);
  } on Object {
    keep.close();
    rethrow;
  }
}, retry: (_, _) => null);

/// Shows what [words] mean, one page each (a tapped cell can sit in two).
Future<void> showMeanings(BuildContext context, List<String> words) {
  if (words.isEmpty) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Palette.soot,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
      child: SafeArea(child: _MeaningPages(words: words)),
    ),
  );
}

class _MeaningPages extends StatefulWidget {
  const _MeaningPages({required this.words});

  final List<String> words;

  @override
  State<_MeaningPages> createState() => _MeaningPagesState();
}

class _MeaningPagesState extends State<_MeaningPages> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final words = widget.words;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (words.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < words.length; i++)
                  ChoiceChip(label: Text(words[i]), selected: i == _page, onSelected: (_) => setState(() => _page = i)),
              ],
            ),
          ),
        Flexible(
          child: MeaningView(word: words[_page], key: ValueKey(words[_page])),
        ),
      ],
    );
  }
}

/// One word's meaning, with a button to hear it. Words the offline lexicon
/// lacks are looked up online.
class MeaningView extends ConsumerWidget {
  const MeaningView({super.key, required this.word});

  final String word;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final offline = ref.watch(meaningProvider(word));
    final online = switch (offline) {
      AsyncData(value: null) || AsyncError() => ref.watch(onlineMeaningProvider(word)),
      _ => null,
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(word.toUpperCase(), style: displayStyle(28, color: Palette.molten)),
              ),
              IconButton(
                tooltip: 'Hear it',
                onPressed: () => ref.read(speakerProvider).say(word),
                icon: GameIcon('speaker', size: 26, color: Palette.whiteHeat),
              ),
            ],
          ),
          switch (online ?? offline) {
            AsyncData(:final value?) => _Senses(meaning: value),
            AsyncData() || AsyncError() => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                "This one isn't in the forge's lexicon, but it's a real word.",
                style: text.bodyMedium?.copyWith(color: Palette.steel),
              ),
            ),
            _ when online != null => Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Palette.molten),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      "Not in the forge's lexicon. Looking further afield…",
                      style: text.bodyMedium?.copyWith(color: Palette.steel),
                    ),
                  ),
                ],
              ),
            ),
            _ => Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(color: Palette.molten)),
            ),
          },
        ],
      ),
    );
  }
}

/// A meaning's numbered senses, and where online ones came from.
class _Senses extends StatelessWidget {
  const _Senses({required this.meaning});

  final Meaning meaning;

  /// Both dictionaries serve Wiktionary's text (CC BY-SA), so it's credited.
  static String _from(String source) => switch (source) {
    'wiktionary' => 'From Wiktionary',
    'dictionaryapi.dev' => 'From Wiktionary, via the Free Dictionary API',
    _ => 'From an online dictionary',
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (meaning.base != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'A form of ${meaning.base}',
              style: text.bodyMedium?.copyWith(color: Palette.steel, fontStyle: FontStyle.italic),
            ),
          ),
        for (final (i, s) in meaning.senses.indexed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: Text('${i + 1}.', style: text.bodyMedium?.copyWith(color: Palette.molten)),
                ),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        if (s.posLabel.isNotEmpty)
                          TextSpan(
                            text: '${s.posLabel}  ',
                            style: text.labelMedium?.copyWith(color: Palette.steel),
                          ),
                        TextSpan(text: s.gloss, style: text.bodyLarge),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (meaning.source case final source?)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Row(
              children: [
                GameIcon('book', size: 15, color: Palette.steel),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _from(source),
                    style: text.labelMedium?.copyWith(color: Palette.steel, fontStyle: FontStyle.italic),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
