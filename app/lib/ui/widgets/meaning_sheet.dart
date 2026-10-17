import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../data/lexicon.dart';
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
                  ChoiceChip(
                    label: Text(words[i]),
                    selected: i == _page,
                    onSelected: (_) => setState(() => _page = i),
                  ),
              ],
            ),
          ),
        Flexible(child: MeaningView(word: words[_page], key: ValueKey(words[_page]))),
      ],
    );
  }
}

/// One word's meaning, with a button to hear it.
class MeaningView extends ConsumerWidget {
  const MeaningView({super.key, required this.word});

  final String word;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final meaning = ref.watch(meaningProvider(word));
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
                icon: const GameIcon('speaker', size: 26, color: Palette.whiteHeat),
              ),
            ],
          ),
          switch (meaning) {
            AsyncData(:final value?) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (value.base != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      'A form of ${value.base}',
                      style: text.bodyMedium?.copyWith(color: Palette.steel, fontStyle: FontStyle.italic),
                    ),
                  ),
                for (final (i, s) in value.senses.indexed)
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
              ],
            ),
            AsyncData() || AsyncError() => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                "This one isn't in the forge's lexicon, but it's a real word.",
                style: text.bodyMedium?.copyWith(color: Palette.steel),
              ),
            ),
            _ => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(color: Palette.molten)),
            ),
          },
        ],
      ),
    );
  }
}
