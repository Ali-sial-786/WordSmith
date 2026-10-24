import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/providers.dart';
import '../../game/word_history.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/meaning_sheet.dart';

/// Every word I've found, newest first: the grid words I forged on one tab,
/// the bonus words that went to my Scrap Bin on the other. Each opens its
/// meaning. Drawn from the puzzle history on this phone.
class WordsScreen extends ConsumerWidget {
  const WordsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final words = WordHistory.from(ref.watch(historyProvider));
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Word history', style: displayStyle(22)),
          centerTitle: true,
          bottom: TabBar(
            indicatorColor: Palette.molten,
            labelColor: Palette.molten,
            tabs: [
              Tab(text: 'Game words (${words.game.length})'),
              Tab(text: 'Scrap Bin (${words.scrap.length})'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _WordList(
              key: const ValueKey('words-game'),
              entries: words.game,
              color: Palette.molten,
              empty: 'The words you forge in every game show up here, newest first.',
            ),
            _WordList(
              key: const ValueKey('words-scrap'),
              entries: words.scrap,
              color: Palette.verdigris,
              empty: 'Bonus words you find that aren\'t in the mold land in your Scrap Bin, and show up here.',
            ),
          ],
        ),
      ),
    );
  }
}

class _WordList extends StatelessWidget {
  const _WordList({super.key, required this.entries, required this.color, required this.empty});

  final List<WordEntry> entries;
  final Color color;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          empty,
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: Palette.steel),
        ),
      );
    }
    final local = MaterialLocalizations.of(context);
    final today = DateUtils.dateOnly(DateTime.now());
    String day(DateTime d) => switch (today.difference(DateUtils.dateOnly(d)).inDays) {
      0 => 'Today',
      1 => 'Yesterday',
      _ => local.formatMediumDate(d),
    };
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        final at = DateTime.fromMillisecondsSinceEpoch(e.at);
        final heading = i == 0 || day(DateTime.fromMillisecondsSinceEpoch(entries[i - 1].at)) != day(at);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (heading)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
                child: Text(day(at), style: text.titleSmall?.copyWith(color: Palette.steel)),
              ),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => showMeanings(context, [e.word]),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(e.word, style: letterStyle(18, color: color)),
                    ),
                    Flexible(
                      child: Text(
                        '${e.from} · ${local.formatTimeOfDay(TimeOfDay.fromDateTime(at))}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: text.bodySmall?.copyWith(color: Palette.steel),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
