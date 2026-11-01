import 'package:flutter/material.dart';

import '../../game/rune_session.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/meaning_sheet.dart';
import '../vs/team_widgets.dart' show teamName;
import 'rune_board.dart';
import 'rune_widgets.dart';

/// Where [word] lies on the grid: a path of touching tiles spelling it, each
/// used once; null if there is none.
List<int>? runePathOf(List<String> tiles, int size, String word) {
  List<int>? from(List<int> path, int at) {
    if (at == word.length) return path;
    for (var i = 0; i < tiles.length; i++) {
      if (path.contains(i) || (path.isNotEmpty && !runeTilesTouch(path.last, i, size))) continue;
      final t = tiles[i];
      if (word.startsWith(t, at)) {
        final found = from([...path, i], at + t.length);
        if (found != null) return found;
      }
    }
    return null;
  }

  return word.isEmpty ? null : from(const [], 0);
}

/// A finished round to look back on: its grid, each racer's words with what
/// they scored (gold: nobody else found it), and every word on the grid,
/// the ones nobody found dimmed. Tap a word to see it on the grid; hold it
/// for its meaning.
class RuneRoundReview extends StatefulWidget {
  const RuneRoundReview({super.key, required this.session, required this.end, this.counted, this.focus});

  final RuneSession session;
  final RuneRoundEnd end;

  /// While the words are being counted: how many of each racer's words have
  /// been so far. The rest wait dimmed, and nothing gives the winner away.
  final int? counted;

  /// The word being counted, lit on the grid (unless one is tapped).
  final String? focus;

  @override
  State<RuneRoundReview> createState() => _RuneRoundReviewState();
}

class _RuneRoundReviewState extends State<RuneRoundReview> {
  String? _shown;
  bool _all = false;

  /// Words listed before "Show all".
  static const _firstWords = 40;

  void _show(String word) => setState(() => _shown = _shown == word ? null : word);

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final end = widget.end;
    final text = Theme.of(context).textTheme;
    final counted = widget.counted;
    final counting = counted != null;
    final lit = _shown ?? (counting ? widget.focus : null);
    final path = lit == null ? null : runePathOf(end.tiles, end.size, lit);
    // Counting: in the room's order, so the order doesn't give the winner away.
    final seats = [...?s.lobby?.players.map((p) => p.id)];
    int seat(String id) => seats.contains(id) ? seats.indexOf(id) : seats.length;
    final racers = end.found.keys.toList()
      ..sort((a, b) {
        if (end.isTeam) {
          final byTeam = (s.teamOf(a) ?? 0).compareTo(s.teamOf(b) ?? 0);
          if (byTeam != 0) return byTeam;
        }
        return counting ? seat(a).compareTo(seat(b)) : (end.points[b] ?? 0).compareTo(end.points[a] ?? 0);
      });
    int pointsOf(String id) =>
        counting ? end.found[id]!.take(counted).fold(0, (sum, w) => sum + w.points) : end.points[id] ?? 0;
    final found = end.foundWords;
    final all = _all ? end.words : end.words.take(_firstWords).toList();
    Widget chip(String word, {int? points, bool unique = false, bool missed = false, Color? color}) => GestureDetector(
      onLongPress: () => showMeanings(context, [word]),
      child: RuneWordChip(
        word: word,
        points: points,
        unique: unique,
        missed: missed && _shown != word,
        color: _shown == word ? Palette.molten : color,
        onTap: () => _show(word),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: SizedBox(
            width: 210,
            height: 210,
            child: RuneBoard(tiles: end.tiles, size: end.size, enabled: false, highlight: path ?? const []),
          ),
        ),
        SizedBox(
          height: 20,
          child: Text(
            lit ?? 'Tap a word to see it on the grid',
            textAlign: TextAlign.center,
            style: text.labelMedium?.copyWith(color: lit == null ? Palette.steel : Palette.molten),
          ),
        ),
        const SizedBox(height: 6),
        if (end.isTeam && end.teamPoints != null && !counting)
          Row(
            children: [
              for (final team in const [0, 1]) ...[
                if (team == 1) const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      color: Palette.team(team).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: team == end.team ? Palette.molten : Palette.team(team),
                        width: team == end.team ? 2 : 1,
                      ),
                    ),
                    child: Text(
                      '${teamName(team)}${team == s.myTeam ? ' (you)' : ''}: ${end.teamPoints![team]}',
                      textAlign: TextAlign.center,
                      style: text.titleSmall?.copyWith(color: Palette.team(team)),
                    ),
                  ),
                ),
              ],
            ],
          ),
        for (final id in racers)
          Container(
            key: ValueKey('rune-found-$id'),
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            decoration: BoxDecoration(
              color: Palette.soot.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(12),
              border: Border(left: BorderSide(color: s.colorOf(id), width: 4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        id == s.me ? 'You' : s.nameOf(id),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall?.copyWith(
                          color: end.isTeam && s.teamOf(id) != null ? Palette.team(s.teamOf(id)!) : s.colorOf(id),
                        ),
                      ),
                    ),
                    Text(
                      '${end.found[id]!.length} ${end.found[id]!.length == 1 ? 'word' : 'words'} · '
                      '${pointsOf(id)} pts',
                      key: ValueKey('rune-found-points-$id'),
                      style: displayStyle(
                        14,
                        color: id == end.winner && !counting ? Palette.molten : Palette.whiteHeat,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (end.found[id]!.isEmpty)
                  Text('No words this round', style: text.bodySmall)
                else
                  Wrap(
                    spacing: 5,
                    runSpacing: 5,
                    children: [
                      for (final (i, w) in end.found[id]!.indexed)
                        if (!counting || i < counted)
                          chip(
                            w.word,
                            points: w.points,
                            unique: w.unique,
                            color: counting && i == counted - 1 ? Palette.molten : null,
                          )
                        // Not counted yet: there, but dim and unscored.
                        else
                          chip(w.word, missed: true),
                    ],
                  ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        Text(
          'Every word on the grid: ${end.total}',
          textAlign: TextAlign.center,
          style: displayStyle(16, color: Palette.molten),
        ),
        Text(
          '${found.length} found · the rest nobody spotted',
          textAlign: TextAlign.center,
          style: text.labelMedium?.copyWith(color: Palette.steel),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 5,
          runSpacing: 5,
          alignment: WrapAlignment.center,
          children: [for (final w in all) chip(w, points: runeWordPoints(w.length), missed: !found.contains(w))],
        ),
        if (!_all && end.words.length > _firstWords)
          TextButton(
            key: const ValueKey('rune-all-words'),
            onPressed: () => setState(() => _all = true),
            child: Text('Show all ${end.words.length}${end.total > end.words.length ? ' of ${end.total}' : ''}'),
          ),
      ],
    );
  }
}
