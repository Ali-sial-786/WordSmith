import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engine/puzzle.dart';
import '../../game/providers.dart';
import '../../game/vs_session.dart';
import '../../net/room_client.dart';
import '../../ui/mold/mold_grid.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/meaning_sheet.dart';
import '../../ui/widgets/metal_button.dart';
import 'rival_molds.dart';
import 'series_summary.dart';

/// Opens the look back at [round] (its number) of the series that just
/// ended, over the podium. It closes by itself when the room moves on (a
/// rematch, or the room closing), so the room screen can show what's next.
Future<void> showRoundReview(
  BuildContext context, {
  required VsSession session,
  required SeriesEnd series,
  required int round,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => _ReviewScreen(session: session, series: series, round: round),
  ),
);

class _ReviewScreen extends StatefulWidget {
  const _ReviewScreen({required this.session, required this.series, required this.round});

  final VsSession session;
  final SeriesEnd series;
  final int round;

  @override
  State<_ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<_ReviewScreen> {
  ModalRoute<Object?>? _route;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final s = widget.session;
    if (s.seriesEnd != null && s.phase == 'results' && s.connection != RoomConnection.closed) return;
    final route = _route;
    if (_closed || !mounted || route == null || !route.isActive) return;
    _closed = true;
    // Whatever is open over it (a word's meaning) goes too.
    Navigator.of(context)
      ..popUntil((r) => r == route)
      ..pop();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ForgeBackground(
      image: 'assets/images/bg_hall.webp',
      fire: 0.5,
      fireHeight: 0.3,
      dim: 0.7,
      child: SafeArea(
        child: RoundReview(
          session: widget.session,
          series: widget.series,
          round: widget.round,
          onPodium: () => Navigator.of(context).maybePop(),
        ),
      ),
    ),
  );
}

/// A look back at a finished Versus series, a page per round: the whole mold
/// with the words I forged and the ones I missed, every racer's mold, and
/// everyone's Scrap Bin. Every word opens its meaning. Swipe, or step from
/// round to round, and back to the podium.
class RoundReview extends ConsumerStatefulWidget {
  const RoundReview({
    super.key,
    required this.session,
    required this.series,
    required this.round,
    required this.onPodium,
  });

  final VsSession session;
  final SeriesEnd series;

  /// The round it opens on, by number.
  final int round;
  final VoidCallback onPodium;

  @override
  ConsumerState<RoundReview> createState() => _RoundReviewState();
}

class _RoundReviewState extends ConsumerState<RoundReview> {
  /// Each round's token in the strip, gaps included.
  static const _token = 46.0;
  static const _stripPad = 14.0;

  late int _index = max(0, widget.series.history.indexWhere((r) => r.round == widget.round));
  late final _pages = PageController(initialPage: _index);
  final _strip = ScrollController();

  bool get _reducedMotion => ref.read(settingsProvider).reducedMotion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(animate: false));
  }

  @override
  void dispose() {
    _pages.dispose();
    _strip.dispose();
    super.dispose();
  }

  /// Scrolls the strip to the open round's token, centred where it can be.
  void _reveal({bool animate = true}) {
    if (!mounted || !_strip.hasClients) return;
    final p = _strip.position;
    final to = (_stripPad + _index * _token + _token / 2 - p.viewportDimension / 2).clamp(0.0, p.maxScrollExtent);
    if (animate && !_reducedMotion) {
      _strip.animateTo(to, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
    } else {
      _strip.jumpTo(to);
    }
  }

  void _go(int index) {
    if (index < 0 || index >= widget.series.history.length || index == _index) return;
    if (_reducedMotion) {
      _pages.jumpToPage(index);
    } else {
      _pages.animateToPage(index, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.series.history;
    if (history.isEmpty) return const SizedBox.shrink();
    final s = widget.session;
    final ids = seriesRacers(widget.series);
    final round = history[_index];
    // A server from before the words keeps none; the round this phone saw end still has them.
    final end = s.standings;
    List<(int, String)> answersOf(SeriesRound r) =>
        r.answers.isEmpty && end != null && end.round == r.round ? end.answers : r.answers;
    return Column(
      children: [
        _Header(round: round, onBack: widget.onPodium),
        SizedBox(
          height: 50,
          child: ListView.builder(
            controller: _strip,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: _stripPad),
            itemExtent: _token,
            itemCount: history.length,
            itemBuilder: (context, i) => _RoundToken(
              key: ValueKey('review-token-${history[i].round}'),
              round: history[i],
              open: i == _index,
              color: history[i].team != null
                  ? Palette.team(history[i].team!)
                  : history[i].winner == null
                  ? null
                  : s.colorOf(history[i].winner),
              onTap: () => _go(i),
            ),
          ),
        ),
        Expanded(
          child: PageView.builder(
            controller: _pages,
            itemCount: history.length,
            onPageChanged: (i) {
              setState(() => _index = i);
              _reveal();
            },
            itemBuilder: (context, i) =>
                _RoundPage(session: s, round: history[i], answers: answersOf(history[i]), ids: ids),
          ),
        ),
        _Steps(
          prev: _index > 0 ? history[_index - 1] : null,
          next: _index < history.length - 1 ? history[_index + 1] : null,
          onPrev: () => _go(_index - 1),
          onNext: () => _go(_index + 1),
          onPodium: widget.onPodium,
        ),
      ],
    );
  }
}

/// Back to the podium, and which round this is.
class _Header extends StatelessWidget {
  const _Header({required this.round, required this.onBack});

  final SeriesRound round;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final survival = round.saved.isNotEmpty || round.reason == 'melted';
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back to the podium',
            onPressed: onBack,
            icon: GameIcon('back', size: 24, color: Palette.steel),
          ),
          Expanded(child: Text('Round ${round.round}', maxLines: 1, style: displayStyle(22))),
          if (round.suddenDeath) _Tag('Sudden death', color: Palette.quenchRed),
          if (survival) _Tag('Survival', color: Palette.molten),
          const SizedBox(width: 12),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: 0.7)),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700),
    ),
  );
}

/// A round in the strip: its number (red for sudden death) over a bar in its
/// winner's colour, ringed while it's the one open.
class _RoundToken extends StatelessWidget {
  const _RoundToken({super.key, required this.round, required this.open, required this.color, required this.onTap});

  final SeriesRound round;
  final bool open;

  /// The winner's colour; null if nobody won.
  final Color? color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = round.suddenDeath ? Palette.quenchRed : (open ? Palette.molten : Palette.steel);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Ink(
            decoration: BoxDecoration(
              color: open ? Palette.soot : Palette.forgeBlack.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: open ? Palette.molten : Palette.ash, width: open ? 1.5 : 1),
              boxShadow: open ? [BoxShadow(color: Palette.ember.withValues(alpha: 0.35), blurRadius: 8)] : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('${round.round}', style: displayStyle(16, color: ink)),
                const SizedBox(height: 3),
                Container(
                  width: 16,
                  height: 3,
                  decoration: BoxDecoration(color: color ?? Palette.ash, borderRadius: BorderRadius.circular(2)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One round, looked back at.
class _RoundPage extends StatelessWidget {
  const _RoundPage({required this.session, required this.round, required this.answers, required this.ids});

  final VsSession session;
  final SeriesRound round;

  /// Its words by slot (none from a server that didn't keep them).
  final List<(int, String)> answers;

  /// Everyone in the series, in podium order.
  final List<String> ids;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final me = s.me;
    final text = Theme.of(context).textTheme;
    final words = {for (final (slot, word) in answers) slot: word};
    final mine = round.molds[me];
    final raced = mine != null;
    // Someone watching sudden death sees every word as forged, in steel.
    final found = raced ? mine.toSet() : {for (final slot in round.slots) slot.slot};
    final color = raced ? s.colorOf(me) : Palette.steel;
    final letters = <CellPos, String>{
      for (final slot in round.slots)
        if (words[slot.slot] case final word?)
          for (final (i, cell) in slot.cells.indexed)
            if (i < word.length) cell: word[i],
    };
    final forgedCells = {
      for (final slot in round.slots)
        if (found.contains(slot.slot)) ...slot.cells,
    };
    final melt = round.melted;
    final meltedCells = {
      if (melt != null && melt.id == me)
        for (final slot in round.slots)
          if (slot.slot == melt.slot)
            for (final cell in slot.cells)
              if (!forgedCells.contains(cell)) cell,
    };
    final rivals = [
      for (final id in ids)
        if (id != me && round.molds.containsKey(id)) id,
    ];
    List<Color> rivalsWith(int slot) => [
      for (final id in rivals)
        if (round.molds[id]!.contains(slot)) s.colorOf(id),
    ];
    // Longest words first.
    final known =
        [
          for (final slot in round.slots)
            if (words[slot.slot] != null) slot.slot,
        ]..sort(
          (a, b) => words[b]!.length != words[a]!.length
              ? words[b]!.length.compareTo(words[a]!.length)
              : words[a]!.compareTo(words[b]!),
        );
    final forged = known.where(found.contains).toList();
    final missed = known.where((slot) => !found.contains(slot)).toList();
    final dots = known.any((slot) => rivalsWith(slot).isNotEmpty);
    final progress = round.progress.where((p) => p.id == me).firstOrNull;
    final saved = round.saved[me];

    void lookUp(List<String> these) => showMeanings(context, these);
    Widget chip(int slot, _Look look) => _WordChip(
      key: ValueKey('word-${words[slot]}'),
      word: words[slot]!,
      look: look,
      color: color,
      rivals: rivalsWith(slot),
      onTap: () => lookUp([words[slot]!]),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
      children: [
        Text.rich(
          TextSpan(children: roundHow(s, round)),
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(color: Palette.steel),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    raced ? 'You found ${found.length} of ${round.slots.length}' : 'You watched this round',
                    style: displayStyle(20, color: raced ? Palette.molten : Palette.whiteHeat),
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(
                      children: [
                        if (progress != null) TextSpan(text: '${progress.filled}/${progress.total} letters'),
                        if (!raced) TextSpan(text: [for (final id in round.molds.keys) s.nameOf(id)].join(' vs ')),
                        if (saved != null) TextSpan(text: ' · $saved saved'),
                      ],
                    ),
                    style: text.labelMedium?.copyWith(color: Palette.steel),
                  ),
                ],
              ),
            ),
            if (round.letters.isNotEmpty) _Anvil(letters: round.letters),
          ],
        ),
        const SizedBox(height: 14),
        _Board(
          round: round,
          letters: letters,
          forged: forgedCells,
          melted: meltedCells,
          color: color,
          onTap: (cell) => lookUp([
            for (final slot in round.slots)
              if (slot.cells.contains(cell) && words[slot.slot] != null) words[slot.slot]!,
          ]),
        ),
        const SizedBox(height: 16),
        if (known.isEmpty)
          _Note("This round's words weren't kept.")
        else if (raced) ...[
          if (forged.isNotEmpty)
            _Group(label: 'Forged', count: forged.length, chips: [for (final w in forged) chip(w, _Look.forged)]),
          if (missed.isNotEmpty) ...[
            if (forged.isNotEmpty) const SizedBox(height: 12),
            _Group(
              label: 'Missed',
              count: missed.length,
              chips: [for (final w in missed) chip(w, melt?.id == me && melt?.slot == w ? _Look.melted : _Look.missed)],
            ),
          ],
        ] else
          _Group(label: 'The words', count: known.length, chips: [for (final w in known) chip(w, _Look.forged)]),
        if (dots) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final id in rivals.take(3)) _Dot(color: s.colorOf(id)),
              const SizedBox(width: 6),
              Text('Rivals who forged it', style: text.labelSmall?.copyWith(color: Palette.steel)),
            ],
          ),
        ],
        _Heading("Everyone's molds"),
        RivalMolds.past(session: s, past: round, order: [me, ...ids], padding: const EdgeInsets.only(top: 16)),
        _Heading('Scrap Bins', icon: 'scrap_bucket'),
        if (round.bins.isEmpty)
          _Note("This round's Scrap Bins weren't kept.")
        else
          Container(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 12),
            decoration: _plate,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final id in [if (raced) me, ...rivals])
                  _Bin(session: s, id: id, words: round.bins[id] ?? const [], onTap: (w) => lookUp([w])),
              ],
            ),
          ),
      ],
    );
  }
}

/// The forged plate a group sits on, as in the podium's round by round.
BoxDecoration get _plate => BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF2C221C), Palette.soot, Color(0xFF1B1411)],
  ),
  borderRadius: BorderRadius.circular(14),
  border: Border.all(color: Palette.ash),
  boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 8, offset: Offset(0, 3))],
);

class _Heading extends StatelessWidget {
  const _Heading(this.label, {this.icon});

  final String label;
  final String? icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[GameIcon(icon!, size: 20, color: Palette.molten), const SizedBox(width: 6)],
        Text(label, style: displayStyle(17, color: Palette.molten)),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Palette.steel),
    ),
  );
}

/// The round's anvil letters, small.
class _Anvil extends StatelessWidget {
  const _Anvil({required this.letters});

  final String letters;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 170),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final letter in letters.split(''))
            Container(
              width: 22,
              height: 22,
              margin: const EdgeInsets.only(left: 3),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF8E8A84), Color(0xFF4E4A46)],
                ),
                border: Border.all(color: const Color(0xFF2A2522)),
              ),
              child: Text(letter, style: letterStyle(12, color: Palette.whiteHeat)),
            ),
        ],
      ),
    ),
  );
}

/// The round's whole mold: my words forged in my colour, the ones I missed
/// as ghosts in their empty sockets (a melted one in red). Any cell opens
/// the meanings of its words.
class _Board extends StatelessWidget {
  const _Board({
    required this.round,
    required this.letters,
    required this.forged,
    required this.melted,
    required this.color,
    required this.onTap,
  });

  final SeriesRound round;
  final Map<CellPos, String> letters;
  final Set<CellPos> forged;
  final Set<CellPos> melted;
  final Color color;
  final ValueChanged<CellPos> onTap;

  static const _maxCell = 54.0;
  static const _maxHeight = 300.0;

  @override
  Widget build(BuildContext context) {
    final cols = round.cols;
    final rows = round.rows;
    if (cols == 0 || rows == 0) return const SizedBox.shrink();
    final cells = {for (final slot in round.slots) ...slot.cells};
    final metal = MetalStyle.fromColor(color);
    return LayoutBuilder(
      builder: (context, c) {
        final cell = min(_maxCell, min(c.maxWidth / cols, _maxHeight / rows));
        final gap = cell * 0.07;
        return Center(
          child: SizedBox(
            width: cell * cols,
            height: cell * rows,
            child: Stack(
              children: [
                for (final pos in cells)
                  Positioned(
                    left: pos.x * cell + gap / 2,
                    top: pos.y * cell + gap / 2,
                    width: cell - gap,
                    height: cell - gap,
                    child: forged.contains(pos)
                        ? MoldCell(
                            key: ValueKey(('forged', pos)),
                            letter: letters[pos] ?? '',
                            fill: CellFill.filled,
                            metal: metal,
                            delay: Duration.zero,
                            flash: 0,
                            onTap: () => onTap(pos),
                          )
                        : _GhostCell(
                            key: ValueKey(('missed', pos)),
                            letter: letters[pos] ?? '',
                            melted: melted.contains(pos),
                            onTap: () => onTap(pos),
                          ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A letter nobody forged on this mold: a ghost in its empty socket, ringed
/// with a broken line (red for the word that melted).
class _GhostCell extends StatelessWidget {
  const _GhostCell({super.key, required this.letter, required this.melted, required this.onTap});

  final String letter;
  final bool melted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = melted ? Palette.quenchRed : Palette.steel;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: LayoutBuilder(
        builder: (context, c) {
          final s = c.maxWidth;
          final radius = BorderRadius.circular(s * 0.16);
          return Stack(
            alignment: Alignment.center,
            children: [
              Image.asset(
                'assets/images/cell_empty.png',
                width: s,
                height: s,
                fit: BoxFit.fill,
                errorBuilder: (_, _, _) => DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF14100D), Color(0xFF2A221C)],
                    ),
                  ),
                  child: SizedBox.square(dimension: s),
                ),
              ),
              if (melted)
                DecoratedBox(
                  decoration: BoxDecoration(borderRadius: radius, color: Palette.quenchRed.withValues(alpha: 0.2)),
                  child: SizedBox.square(dimension: s),
                ),
              CustomPaint(
                size: Size.square(s),
                painter: _Dashes(
                  color: ink.withValues(alpha: melted ? 0.85 : 0.5),
                  radius: s * 0.16,
                  width: max(1.0, s * 0.035),
                  dash: s * 0.13,
                  gap: s * 0.09,
                  inset: s * 0.06,
                ),
              ),
              if (letter.isNotEmpty)
                Text(
                  letter,
                  style: letterStyle(s * 0.54, color: ink.withValues(alpha: melted ? 0.9 : 0.6)),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A broken line round a rounded rectangle.
class _Dashes extends CustomPainter {
  _Dashes({
    required this.color,
    required this.radius,
    required this.width,
    required this.dash,
    required this.gap,
    this.inset = 0,
  });

  final Color color;
  final double radius;
  final double width;
  final double dash;
  final double gap;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(inset + width / 2);
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(max(0, radius - inset))));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += dash + gap) {
        canvas.drawPath(metric.extractPath(d, min(d + dash, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Dashes old) =>
      old.color != color ||
      old.radius != radius ||
      old.width != width ||
      old.dash != dash ||
      old.gap != gap ||
      old.inset != inset;
}

/// "Forged · 3", then its words.
class _Group extends StatelessWidget {
  const _Group({required this.label, required this.count, required this.chips});

  final String label;
  final int count;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$label · $count', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Palette.steel)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: chips),
    ],
  );
}

enum _Look { forged, missed, melted, bonus }

/// A word to tap for its meaning: forged in [color]'s metal, a ghost in a
/// broken outline if missed (red if it melted), or verdigris from a Scrap
/// Bin. [rivals] are the colours of the rivals who forged it.
class _WordChip extends StatelessWidget {
  const _WordChip({
    super.key,
    required this.word,
    required this.look,
    required this.onTap,
    this.color,
    this.rivals = const [],
  });

  final String word;
  final _Look look;
  final VoidCallback onTap;
  final Color? color;
  final List<Color> rivals;

  @override
  Widget build(BuildContext context) {
    final metal = MetalStyle.fromColor(color ?? Palette.steel);
    final radius = BorderRadius.circular(9);
    final (decoration, ink) = switch (look) {
      _Look.forged => (
        BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(metal.base, Colors.white, 0.3)!,
              metal.base,
              Color.lerp(metal.base, Colors.black, 0.3)!,
            ],
          ),
          border: Border.all(color: Color.lerp(metal.base, Colors.black, 0.45)!),
          boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 3, offset: Offset(0, 1))],
        ),
        metal.letter,
      ),
      _Look.missed => (
        BoxDecoration(borderRadius: radius, color: Palette.forgeBlack.withValues(alpha: 0.5)),
        Palette.steel.withValues(alpha: 0.8),
      ),
      _Look.melted => (
        BoxDecoration(borderRadius: radius, color: Palette.quenchRed.withValues(alpha: 0.14)),
        Palette.quenchRed,
      ),
      _Look.bonus => (
        BoxDecoration(
          borderRadius: radius,
          color: Palette.verdigris.withValues(alpha: 0.16),
          border: Border.all(color: Palette.verdigris.withValues(alpha: 0.6)),
        ),
        Palette.whiteHeat,
      ),
    };
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: CustomPaint(
          foregroundPainter: switch (look) {
            _Look.missed => _Dashes(
              color: Palette.steel.withValues(alpha: 0.55),
              radius: 9,
              width: 1.2,
              dash: 5,
              gap: 3.5,
            ),
            _Look.melted => _Dashes(
              color: Palette.quenchRed.withValues(alpha: 0.85),
              radius: 9,
              width: 1.2,
              dash: 5,
              gap: 3.5,
            ),
            _ => null,
          },
          child: Container(
            decoration: decoration,
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(word, style: letterStyle(15, color: ink)),
                if (rivals.isNotEmpty) ...[const SizedBox(width: 4), for (final c in rivals) _Dot(color: c)],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A rival's colour, ringed dark so it shows on any metal.
class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    margin: const EdgeInsets.only(left: 2),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      border: Border.all(color: const Color(0xAA000000)),
    ),
  );
}

/// One racer's Scrap Bin for the round: the bonus words they found.
class _Bin extends StatelessWidget {
  const _Bin({required this.session, required this.id, required this.words, required this.onTap});

  final VsSession session;
  final String id;
  final List<String> words;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final player = session.lobby?.player(id);
    final mine = id == session.me;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Opacity(
                opacity: player == null || !player.connected ? 0.5 : 1,
                child: AvatarBadge(avatar: player?.avatar ?? 'avatar_01', size: 22),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  mine ? 'You' : session.nameOf(id),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall?.copyWith(color: mine ? Palette.whiteHeat : session.colorOf(id)),
                ),
              ),
              Text(switch (words.length) {
                0 => 'no bonus words',
                1 => '1 bonus word',
                final n => '$n bonus words',
              }, style: text.labelSmall?.copyWith(color: Palette.steel)),
            ],
          ),
          if (words.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final w in words)
                  _WordChip(key: ValueKey('bin-$id-$w'), word: w, look: _Look.bonus, onTap: () => onTap(w)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The previous and next rounds, and the podium between them.
class _Steps extends StatelessWidget {
  const _Steps({
    required this.prev,
    required this.next,
    required this.onPrev,
    required this.onNext,
    required this.onPodium,
  });

  final SeriesRound? prev;
  final SeriesRound? next;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPodium;

  @override
  Widget build(BuildContext context) {
    final prev = this.prev;
    final next = this.next;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Palette.forgeBlack.withValues(alpha: 0.55), Palette.forgeBlack.withValues(alpha: 0.9)],
        ),
        border: Border(top: BorderSide(color: Palette.ash)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: prev == null
                    ? null
                    : TextButton.icon(
                        key: const ValueKey('review-prev'),
                        onPressed: onPrev,
                        icon: const Icon(Icons.chevron_left),
                        label: Text('Round ${prev.round}'),
                      ),
              ),
            ),
            ForgeChipButton(key: const ValueKey('review-podium'), label: 'Podium', icon: 'trophy', onPressed: onPodium),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: next == null
                    ? null
                    : TextButton.icon(
                        key: const ValueKey('review-next'),
                        onPressed: onNext,
                        iconAlignment: IconAlignment.end,
                        icon: const Icon(Icons.chevron_right),
                        label: Text('Round ${next.round}'),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
