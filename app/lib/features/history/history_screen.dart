import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/history.dart';
import '../../game/account.dart';
import '../../game/providers.dart';
import '../../game/vs_session.dart';
import '../../net/room_client.dart';
import '../../ui/mold/mold_grid.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_frame.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/meaning_sheet.dart';
import '../vs/series_summary.dart';
import 'history_mold.dart';

/// The filters along the top: what each shows.
enum _Filter {
  all('All', {}),
  campaign('Campaign', {PlayKind.campaign, PlayKind.replay}),
  daily('Daily', {PlayKind.daily}),
  crucible('Crucible', {PlayKind.crucible}),
  coop('Co-op', {PlayKind.coop}),
  vs('Versus', {PlayKind.vs});

  const _Filter(this.label, this.kinds);
  final String label;
  final Set<PlayKind> kinds;

  bool shows(PlayRecord r) => kinds.isEmpty || kinds.contains(r.kind);
}

String _icon(PlayKind kind) => switch (kind) {
  PlayKind.campaign => 'map',
  PlayKind.replay => 'turn',
  PlayKind.daily => 'calendar',
  PlayKind.crucible => 'flame',
  PlayKind.coop => 'friends',
  PlayKind.vs => 'trophy',
};

String _duration(int ms) {
  final s = ms ~/ 1000;
  if (s >= 3600) return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String _ordinal(int n) => switch (n % 100) {
  11 || 12 || 13 => '${n}th',
  _ => switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  },
};

/// The one-line result shown in the list.
String resultLine(PlayRecord r) {
  final board = r.boards.firstOrNull;
  switch (r.kind) {
    case PlayKind.campaign || PlayKind.replay || PlayKind.daily:
      final words = board?.puzzle.slots.length ?? 0;
      final bonus = board?.bonus.length ?? 0;
      return [
        '$words words',
        if (bonus > 0) '+$bonus bonus',
        if (r.get<int>('elapsedMs') case final ms? when ms > 0) _duration(ms),
      ].join(' · ');
    case PlayKind.crucible:
      final cleared = r.get<int>('cleared') ?? 0;
      return '$cleared cleared · ${r.get<int>('saved') ?? 0} saved';
    case PlayKind.coop:
      final stars = r.get<int>('stars') ?? 0;
      return '$stars of 3 stars · Team ${r.get<int>('teamScore') ?? 0}';
    case PlayKind.vs:
      final winner = r.get<String>('winner');
      final wins = r.get<int>('wins') ?? 0;
      final place = r.get<int>('place');
      final w = '$wins ${wins == 1 ? 'win' : 'wins'}';
      if (winner != null && winner == r.me) return 'You won · $w';
      return place == null ? w : '${_ordinal(place)} · $w';
  }
}

/// Everything played on this phone, newest first, a day at a time. Tap one
/// to look back at its board.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(historyProvider);
    final records = all.where(_filter.shows).toList();
    final text = Theme.of(context).textTheme;
    final local = MaterialLocalizations.of(context);
    final today = DateUtils.dateOnly(DateTime.now());
    String day(DateTime d) {
      final gap = today.difference(DateUtils.dateOnly(d)).inDays;
      return gap == 0
          ? 'Today'
          : gap == 1
          ? 'Yesterday'
          : local.formatMediumDate(d);
    }

    final rows = <Widget>[];
    String? heading;
    for (final r in records) {
      final at = DateTime.fromMillisecondsSinceEpoch(r.at);
      final label = day(at);
      if (label != heading) {
        heading = label;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
            child: Text(label, style: text.titleSmall?.copyWith(color: Palette.steel)),
          ),
        );
      }
      rows.add(_RecordTile(record: r, time: local.formatTimeOfDay(TimeOfDay.fromDateTime(at))));
    }

    return Scaffold(
      appBar: AppBar(title: Text('Puzzle history', style: displayStyle(22)), centerTitle: true),
      body: Column(
        children: [
          // Every filter in view: two short rows on a phone rather than a strip to scroll.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 6,
              runSpacing: 2,
              children: [
                for (final f in _Filter.values)
                  ChoiceChip(
                    label: Text(f.label),
                    visualDensity: VisualDensity.compact,
                    selected: f == _filter,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
              ],
            ),
          ),
          Expanded(
            child: records.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GameIcon('scroll', size: 56, color: Palette.ash),
                          const SizedBox(height: 12),
                          Text(
                            all.isEmpty
                                ? 'Puzzles you finish on this phone show up here, so you can look back at every '
                                      'word you forged and the ones you missed.'
                                : 'Nothing here yet for ${_filter.label}.',
                            textAlign: TextAlign.center,
                            style: text.bodyMedium?.copyWith(color: Palette.steel),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: rows),
          ),
        ],
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.record, required this.time});

  final PlayRecord record;
  final String time;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = record;
    final won = r.kind == PlayKind.vs && r.get<String>('winner') == r.me && r.me != null;
    final lost = r.kind == PlayKind.crucible || (r.kind == PlayKind.coop && r.get<bool>('completed') == false);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Palette.soot,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlayDetailScreen(record: r))),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: won ? Palette.gold : Palette.ash),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Palette.forgeBlack.withValues(alpha: 0.6),
                    border: Border.all(color: Palette.molten.withValues(alpha: 0.6)),
                  ),
                  child: GameIcon(_icon(r.kind), size: 24, color: Palette.molten),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium?.copyWith(height: 1.15),
                      ),
                      Text(r.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                      const SizedBox(height: 2),
                      Text(
                        resultLine(r),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelLarge?.copyWith(
                          color: won
                              ? Palette.gold
                              : lost
                              ? Palette.steel
                              : Palette.molten,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(time, style: text.labelSmall?.copyWith(color: Palette.steel)),
                    const SizedBox(height: 6),
                    Icon(Icons.chevron_right, color: Palette.steel),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One played puzzle (or run, round or series), looked back at: how it went,
/// the whole board with the words forged and the ones missed, and the bonus
/// words. Every word opens its meaning.
class PlayDetailScreen extends ConsumerStatefulWidget {
  const PlayDetailScreen({super.key, required this.record});

  final PlayRecord record;

  @override
  ConsumerState<PlayDetailScreen> createState() => _PlayDetailScreenState();
}

class _PlayDetailScreenState extends ConsumerState<PlayDetailScreen> {
  /// Versus: a session that never connects, so the series look back can
  /// draw names and colours as they were.
  VsSession? _vs;
  SeriesEnd? _series;

  PlayRecord get _r => widget.record;

  @override
  void initState() {
    super.initState();
    final raw = _r.series;
    if (_r.kind == PlayKind.vs && raw != null) {
      try {
        _series = SeriesEnd.fromJson(raw);
        _vs =
            VsSession(
                client: RoomClient(baseUrl: 'http://history.invalid', code: '', token: () async => null),
                me: _r.me ?? '',
              )
              ..nicknameOf = ref.read(accountProvider.notifier).nicknameOf
              ..lobby = RoomLobby.fromJson({
                'code': _r.get<String>('code') ?? '',
                'mode': 'vs',
                'phase': 'results',
                'hostId': null,
                'heat': 1,
                'players': [
                  for (final p in _r.players)
                    {
                      'id': p.id,
                      'username': p.username,
                      'avatar': p.avatar,
                      'color': p.color,
                      'ready': true,
                      'connected': true,
                    },
                ],
              })
              ..seriesEnd = _series;
      } on Object {
        _series = null;
        _vs = null;
      }
    }
  }

  @override
  void dispose() {
    _vs?.dispose();
    super.dispose();
  }

  /// A player's name as I know them now: my nickname for them, else their username then.
  String _name(String id) {
    if (id == _r.me) return 'You';
    return ref.read(accountProvider.notifier).nicknameOf(id) ?? _r.player(id)?.username ?? 'A smith';
  }

  Color _color(String id) => Palette.player(_r.player(id)?.color ?? 0);

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final text = Theme.of(context).textTheme;
    final local = MaterialLocalizations.of(context);
    final at = DateTime.fromMillisecondsSinceEpoch(r.at);
    final when = '${local.formatFullDate(at)}, ${local.formatTimeOfDay(TimeOfDay.fromDateTime(at))}';
    final stage = r.get<int>('stage');
    return Scaffold(
      appBar: AppBar(title: Text(r.title, style: displayStyle(22)), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          Text(r.subtitle, textAlign: TextAlign.center, style: text.titleMedium),
          Text(
            when,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: Palette.steel),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [for (final (icon, label) in _facts()) _Fact(icon: icon, label: label)],
          ),
          const SizedBox(height: 16),
          if (r.kind == PlayKind.coop) ...[
            _CoopTeam(record: r, name: _name, color: _color),
            const SizedBox(height: 16),
          ],
          if (r.kind == PlayKind.vs)
            if (_vs != null && _series != null && _series!.history.isNotEmpty) ...[
              Text('Tap a round to go back over it.', textAlign: TextAlign.center, style: text.bodySmall),
              const SizedBox(height: 8),
              SeriesSummary(session: _vs!, series: _series!),
            ] else
              Text('This series has no rounds to show.', textAlign: TextAlign.center, style: text.bodyMedium),
          for (final (i, board) in r.boards.indexed) ...[
            if (r.boards.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 6),
                child: Text(_crucibleHeading(i, board), style: text.titleMedium),
              ),
            _BoardPanel(
              board: board,
              look: r.look,
              colorOf: r.kind == PlayKind.coop ? (id) => _color(id) : null,
              initialOf: r.kind == PlayKind.coop
                  ? (id) {
                      final name = _name(id);
                      return name.isEmpty ? null : String.fromCharCode(name.runes.first).toUpperCase();
                    }
                  : null,
            ),
            const SizedBox(height: 16),
          ],
          if ((r.kind == PlayKind.campaign || r.kind == PlayKind.replay) && stage != null)
            OutlinedButton.icon(
              icon: const Icon(Icons.replay),
              label: const Text('Play it again'),
              onPressed: () => context.push('/replay/$stage'),
            ),
        ],
      ),
    );
  }

  String _crucibleHeading(int i, PlayedBoard b) {
    final how = b.melted != null
        ? 'melted'
        : b.complete
        ? 'cleared'
        : 'left unfinished';
    return 'Puzzle ${i + 1} · $how';
  }

  /// The facts along the top, as (icon, label).
  List<(IconData, String)> _facts() {
    final r = _r;
    final xp = r.get<int>('xp');
    final ms = r.get<int>('elapsedMs');
    final hints = r.get<int>('hints');
    return switch (r.kind) {
      PlayKind.campaign || PlayKind.replay || PlayKind.daily => [
        if (ms != null && ms > 0) (Icons.timer_outlined, _duration(ms)),
        (Icons.lightbulb_outline, hints == null || hints == 0 ? 'No hints' : '$hints ${hints == 1 ? 'hint' : 'hints'}'),
        if (xp != null && xp > 0) (Icons.add, '$xp XP'),
      ],
      PlayKind.crucible => [
        (Icons.check, '${r.get<int>('cleared') ?? 0} cleared'),
        (Icons.local_fire_department_outlined, '${r.get<int>('saved') ?? 0} saved'),
        (Icons.text_fields, '${r.get<int>('words') ?? 0} words'),
        if (ms != null && ms > 0) (Icons.timer_outlined, _duration(ms)),
      ],
      PlayKind.coop => [
        (
          Icons.star_outline,
          r.get<bool>('completed') == true
              ? 'Mold filled'
              : r.get<bool>('melted') == true
              ? 'It melted'
              : "Time's up",
        ),
        (Icons.grid_on, '${r.get<int>('filled') ?? 0}/${r.get<int>('total') ?? 0} letters'),
        if (xp != null && xp > 0) (Icons.add, '$xp XP'),
      ],
      PlayKind.vs => [
        (Icons.emoji_events_outlined, resultLine(r)),
        (Icons.repeat, '${r.get<int>('rounds') ?? 0} rounds'),
        if (xp != null && xp > 0) (Icons.add, '$xp XP'),
      ],
    };
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: Palette.soot,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Palette.ash),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Palette.molten),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.labelLarge),
      ],
    ),
  );
}

/// Co-op: everyone's points and words, best first, the MVP crowned.
class _CoopTeam extends StatelessWidget {
  const _CoopTeam({required this.record, required this.name, required this.color});

  final PlayRecord record;
  final String Function(String id) name;
  final Color Function(String id) color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final points = ((record.result['points'] as Map?) ?? const {}).cast<String, Object?>();
    final words = ((record.result['words'] as Map?) ?? const {}).cast<String, Object?>();
    final ids = points.keys.toList()..sort((a, b) => ((points[b] as num?) ?? 0).compareTo((points[a] as num?) ?? 0));
    final mvp = record.get<String>('mvp');
    return ForgePanel(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text('Team ${record.get<int>('teamScore') ?? 0}', style: text.titleMedium)),
              for (var i = 0; i < 3; i++)
                GameIcon('star', size: 20, color: i < (record.get<int>('stars') ?? 0) ? Palette.molten : Palette.ash),
            ],
          ),
          const SizedBox(height: 4),
          for (final id in ids)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: color(id), shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(name(id), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (id == mvp) ...[GameIcon('crown', size: 16, color: Palette.gold), const SizedBox(width: 6)],
                  Text(
                    '${(words[id] as num?) ?? 0} words · ${(points[id] as num?) ?? 0}',
                    style: text.labelLarge?.copyWith(color: Palette.steel),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A finished board, its words and bonus words.
class _BoardPanel extends ConsumerWidget {
  const _BoardPanel({required this.board, required this.look, this.colorOf, this.initialOf});

  final PlayedBoard board;
  final String look;
  final Color? Function(String id)? colorOf;
  final String? Function(String id)? initialOf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final mold = HistoryMold(board, colorOf: colorOf, initialOf: initialOf);
    final words = [...board.puzzle.slots]
      ..sort((a, b) => b.length != a.length ? b.length - a.length : a.word.compareTo(b.word));
    final missed = board.missed.toSet();
    final reducedMotion = ref.watch(settingsProvider.select((s) => s.reducedMotion));
    return ForgePanel(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Just the board's own height, its cells as big as fit (up to 44).
          LayoutBuilder(
            builder: (context, c) => SizedBox(
              height: min(44.0, c.maxWidth / board.puzzle.cols) * board.puzzle.rows,
              child: MoldGrid(
                mold: mold,
                metal: MetalStyle.forChapter(look),
                cues: MoldCues(),
                maxCell: 44,
                reducedMotion: reducedMotion,
                onFilledTap: (c) => showMeanings(context, mold.wordsAt(c)),
              ),
            ),
          ),
          if (missed.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Glowing letters are the words ${board.owners.isEmpty ? 'you' : 'the team'} missed.',
                textAlign: TextAlign.center,
                style: text.bodySmall,
              ),
            ),
          const SizedBox(height: 10),
          Text(
            missed.isEmpty
                ? 'Words (${words.length})'
                : 'Words: ${words.length - missed.length} of ${words.length} forged',
            style: text.titleSmall,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in words)
                _WordChip(
                  word: s.word,
                  missed: missed.contains(s),
                  melted: board.melted == s.index,
                  color: board.owners[s.index] == null ? null : colorOf?.call(board.owners[s.index]!),
                ),
            ],
          ),
          if (board.bonus.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Bonus words (${board.bonus.length})', style: text.titleSmall),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final w in board.bonus) _WordChip(word: w, bonus: true)]),
          ],
        ],
      ),
    );
  }
}

class _WordChip extends StatelessWidget {
  const _WordChip({required this.word, this.missed = false, this.melted = false, this.bonus = false, this.color});

  final String word;
  final bool missed;
  final bool melted;
  final bool bonus;

  /// Co-op: the colour of whoever forged it.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final edge = melted
        ? Palette.quenchRed
        : missed
        ? Palette.molten
        : color ?? (bonus ? Palette.verdigris : Palette.ash);
    return Material(
      color: missed ? Palette.molten.withValues(alpha: 0.12) : Palette.forgeBlack.withValues(alpha: 0.55),
      shape: StadiumBorder(
        side: BorderSide(color: edge, width: missed ? 1.6 : 1.2),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => showMeanings(context, [word]),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(word.toUpperCase(), style: letterStyle(15, color: missed ? Palette.molten : Palette.whiteHeat)),
        ),
      ),
    );
  }
}
