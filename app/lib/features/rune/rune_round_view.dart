import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/sfx.dart';
import '../../game/providers.dart';
import '../../game/rune_session.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/meaning_sheet.dart';
import '../../ui/widgets/toast_line.dart';
import '../../ui/widgets/video_bubble.dart';
import '../../ui/widgets/word_preview.dart';
import '../coop/emotes.dart';
import '../coop/room_chat.dart';
import '../coop/room_video.dart';
import 'rune_board.dart';
import 'rune_widgets.dart';

/// A Rune Rush round: the grid of letter dice to swipe words on, the timer,
/// rivals' word counts, and my words so far.
class RuneRoundView extends ConsumerStatefulWidget {
  const RuneRoundView({super.key, required this.session, required this.onLeave, this.video = RoomVideo.none});

  final RuneSession session;
  final VoidCallback onLeave;
  final RoomVideo video;

  @override
  ConsumerState<RuneRoundView> createState() => _RuneRoundViewState();
}

class _RuneRoundViewState extends ConsumerState<RuneRoundView> {
  final _board = GlobalKey<RuneBoardState>();
  final _preview = GlobalKey<WordPreviewState>();
  final _toast = GlobalKey<ToastLineState>();
  late final StreamSubscription<RoomEvent> _sub;
  late final Timer _tick;

  /// The clock as last built.
  (int, int)? _face;
  String _word = '';

  /// How the grid is turned, in quarter turns (the letters stay upright).
  int _turns = 0;

  /// Words sent and waiting for their result, with the tiles they took.
  final Map<String, List<int>> _pending = {};

  /// The seconds last ticked, near the end.
  int _ticked = -1;

  RuneSession get _s => widget.session;
  Sfx get _sfx => ref.read(sfxProvider);

  @override
  void initState() {
    super.initState();
    _sub = _s.effects.listen(_onEffect);
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      final secs = _s.timeLeft.inSeconds;
      if (_playing && secs < 10 && secs != _ticked) {
        _ticked = secs;
        _sfx.play(SfxId.tick, volume: 0.6);
      }
      // The clock counts whole seconds: rebuild only when it turns over.
      if (_s.clockFace != _face) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    _tick.cancel();
    super.dispose();
  }

  bool get _playing =>
      _s.countdownLeft == Duration.zero &&
      !_s.roundOver &&
      _s.timeLeft > Duration.zero &&
      _s.phase == 'round' &&
      _s.racing;

  void _haptic(void Function() fn) {
    if (ref.read(settingsProvider).haptics) fn();
  }

  void _onEffect(RoomEvent e) {
    if (!mounted) return;
    switch (e) {
      case WordResult(:final word, :final result, :final points, :final by):
        final path = _pending.remove(word) ?? const [];
        switch (result) {
          case 'found':
            _preview.currentState?.react(word, PreviewResult.good);
            _board.currentState?.flash(path, Palette.verdigris, kind: RuneFlash.good, label: '+$points');
            _sfx.play(SfxId.clang);
            _haptic(HapticFeedback.mediumImpact);
            _toast.currentState?.show('$word  +$points', color: Palette.verdigris);
          case 'already':
            _preview.currentState?.react(word, PreviewResult.repeat);
            _board.currentState?.flash(path, Palette.gold, kind: RuneFlash.repeat);
            _sfx.play(SfxId.already);
            _toast.currentState?.show(
              by == null || by == _s.me ? 'You have that one' : '${_s.nameOf(by)} found that one',
            );
          case 'rate_limited':
            _preview.currentState?.react(word, PreviewResult.bad);
            _toast.currentState?.show('Slow down, smith!', color: Palette.quenchRed);
          case 'too_late':
            _preview.currentState?.react(word, PreviewResult.bad);
          default:
            _preview.currentState?.react(word, PreviewResult.bad);
            _board.currentState?.flash(path, Palette.quenchRed, kind: RuneFlash.bad);
            _sfx.play(SfxId.invalid);
        }
      case RuneWordFound():
        _sfx.play(SfxId.clangLight, volume: 0.6);
      case RoomError(:final code) when code == 'not_playing':
        _toast.currentState?.show("You're watching this round", color: Palette.steel);
      default:
        break;
    }
  }

  void _onChanged(String word) {
    if (word.length > _word.length) {
      _sfx.tink(word.length);
      _haptic(HapticFeedback.selectionClick);
    }
    setState(() => _word = word);
  }

  void _onSubmit(String word, List<int> path) {
    if (!_playing) return;
    if (path.length == 1) return;
    if (word.length < _s.minLength) {
      _preview.currentState?.react(word, PreviewResult.bad);
      _board.currentState?.flash(path, Palette.quenchRed, kind: RuneFlash.bad);
      _toast.currentState?.show('Words need ${_s.minLength} letters or more', color: Palette.steel);
      return;
    }
    if (_s.has(word)) {
      final by = _s.mine.firstWhere((w) => w.word == word).by;
      _preview.currentState?.react(word, PreviewResult.repeat);
      _board.currentState?.flash(path, Palette.gold, kind: RuneFlash.repeat);
      _sfx.play(SfxId.already);
      _toast.currentState?.show(by == _s.me ? 'You have that one' : '${_s.nameOf(by)} found that one');
      return;
    }
    _pending[word] = path;
    _s.submit(word);
  }

  List<String>? _blankTiles;
  List<String> _blank(int n) => _blankTiles?.length == n ? _blankTiles! : _blankTiles = List.filled(n, '');

  void _turn() {
    _sfx.play(SfxId.shuffle);
    _board.currentState?.clear();
    setState(() => _turns = (_turns + 1) % 4);
  }

  @override
  Widget build(BuildContext context) {
    final grid = _s.grid!;
    final text = Theme.of(context).textTheme;
    _face = _s.clockFace;
    final counting = _s.countdownLeft > Duration.zero;
    final words = _s.mine.reversed.toList();
    final still = ref.watch(settingsProvider.select((s) => s.reducedMotion));
    final word = _playing ? _word : '';
    final long = word.length >= _s.minLength;
    return Stack(
      children: [
        Column(
          children: [
            _TopStrip(session: _s, onLeave: widget.onLeave, video: widget.video, still: still),
            _TimeBar(session: _s),
            RuneRivalStrip(session: _s, call: widget.video.call),
            if (_s.isTeam) RuneTeamBar(session: _s),
            Expanded(
              // The word being traced and how it went sit right over the grid,
              // the space left over going above and below them.
              child: LayoutBuilder(
                builder: (context, c) {
                  const above = 20 + 48 + 26;
                  final side = max(0.0, min(c.maxWidth - 36, c.maxHeight - above - 16));
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        height: 20,
                        child: _s.feed.isEmpty
                            ? null
                            : Text(_s.feed.first.text, style: text.labelMedium?.copyWith(color: _s.feed.first.color)),
                      ),
                      WordPreview(
                        key: _preview,
                        word: word,
                        // What it would score, once it's long enough to count.
                        badge: long ? '+${runeWordPoints(word.length)}' : null,
                        color: long ? Palette.ember : Palette.steel,
                      ),
                      ToastLine(key: _toast),
                      SizedBox(
                        width: side,
                        height: side + 16,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned.fill(
                                child: RepaintBoundary(
                                  child: RuneBoard(
                                    key: _board,
                                    // Blank until the round starts: everyone sees the letters at once.
                                    tiles: counting ? _blank(grid.tiles.length) : grid.tiles,
                                    size: grid.size,
                                    enabled: _playing,
                                    quarterTurns: _turns,
                                    onChanged: _onChanged,
                                    onSubmit: _onSubmit,
                                    reducedMotion: still,
                                  ),
                                ),
                              ),
                              if (!_s.racing && !counting)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: Text(
                                    "Tiebreaker: ${grid.players.map(_s.nameOf).join(' vs ')}. You're watching this one.",
                                    textAlign: TextAlign.center,
                                    style: text.bodyMedium?.copyWith(color: Palette.molten),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('rune-turn'),
                    tooltip: 'Turn the grid',
                    onPressed: _turn,
                    icon: Icon(Icons.rotate_90_degrees_cw_outlined, color: Palette.steel),
                  ),
                  Expanded(
                    child: Center(
                      child: _Bump(
                        value: _s.myPoints,
                        still: still,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                          decoration: BoxDecoration(
                            color: Palette.forgeBlack.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: _s.colorOf(_s.me).withValues(alpha: 0.7)),
                          ),
                          child: Text(
                            _s.pooled
                                ? 'Your team: ${_s.mine.length} words · ${_s.myPoints} pts'
                                : '${_s.mine.length} ${_s.mine.length == 1 ? 'word' : 'words'} · ${_s.myPoints} pts',
                            key: const ValueKey('rune-mine'),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: displayStyle(16, color: _s.colorOf(_s.me)).copyWith(
                              shadows: [Shadow(color: _s.colorOf(_s.me).withValues(alpha: 0.6), blurRadius: 10)],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Text('${grid.min}+ letters', style: text.labelMedium?.copyWith(color: Palette.steel)),
                ],
              ),
            ),
            SizedBox(
              height: 74,
              child: words.isEmpty
                  ? Center(
                      child: Text(
                        _s.racing ? 'Swipe through touching letters, or tap them' : '',
                        style: text.bodySmall?.copyWith(color: Palette.steel),
                      ),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
                      child: RepaintBoundary(
                        child: Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          children: [
                            for (final (i, w) in words.indexed)
                              _Arrive(
                                key: ValueKey('rune-mine-${w.word}'),
                                // The newest word drops in; the rest are already there.
                                still: still || i > 0,
                                child: RuneWordChip(
                                  word: w.word,
                                  points: w.points,
                                  color: w.by == _s.me ? null : _s.colorOf(w.by),
                                  onTap: () => showMeanings(context, [w.word]),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
            ),
          ],
        ),
        if (counting)
          Positioned.fill(
            child: RuneCountdown(session: _s, still: still),
          ),
        // The clock ran out: a moment until the server's count comes.
        if (!counting && _s.timeLeft == Duration.zero && grid.endsAt > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Palette.forgeBlack.withValues(alpha: 0.55),
                child: Center(
                  child: _Arrive(
                    still: still,
                    from: 0.4,
                    child: Text(
                      "Time's up!",
                      key: const ValueKey('rune-times-up'),
                      style: displayStyle(
                        44,
                        color: Palette.molten,
                      ).copyWith(shadows: [Shadow(color: Palette.ember, blurRadius: 30)]),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// [child] growing in from [from] of its size, once, as it first shows.
class _Arrive extends StatelessWidget {
  const _Arrive({super.key, required this.child, this.still = false, this.from = 0.5});

  final Widget child;
  final bool still;
  final double from;

  @override
  Widget build(BuildContext context) {
    if (still) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: from, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutBack,
      child: child,
      builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
    );
  }
}

/// [child] swelling for a moment whenever [value] goes up.
class _Bump extends StatefulWidget {
  const _Bump({required this.value, required this.child, this.still = false});

  final int value;
  final Widget child;
  final bool still;

  @override
  State<_Bump> createState() => _BumpState();
}

class _BumpState extends State<_Bump> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));

  @override
  void didUpdateWidget(_Bump old) {
    super.didUpdateWidget(old);
    if (widget.value > old.value && !widget.still) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: widget.child,
    builder: (context, child) {
      if (!_c.isAnimating) return child!;
      return Transform.scale(scale: 1 + 0.2 * sin(pi * _c.value), child: child);
    },
  );
}

class _TopStrip extends StatelessWidget {
  const _TopStrip({required this.session, required this.onLeave, required this.video, required this.still});

  final RuneSession session;
  final VoidCallback onLeave;
  final RoomVideo video;
  final bool still;

  @override
  Widget build(BuildContext context) {
    final secs = clockSeconds(session.timeLeft);
    final g = session.grid;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(
            onPressed: onLeave,
            icon: Icon(Icons.close, color: Palette.steel),
          ),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                runeRoundLabel(session),
                style: displayStyle(16, color: g?.tiebreak ?? false ? Palette.quenchRed : Palette.whiteHeat),
              ),
            ),
          ),
          if (video.call != null)
            VideoToggles(call: video.call!, onCamera: video.onCamera, onMic: video.onMic, size: 20),
          ChatButton(session: session, size: 20),
          EmoteButton(onEmote: session.emote, size: 20),
          _RuneClock(
            seconds: session.countdownLeft > Duration.zero ? g?.seconds ?? 0 : secs,
            urgent: session.countdownLeft == Duration.zero && secs <= 10 && secs > 0,
            still: still,
          ),
          const SizedBox(width: 10),
        ],
      ),
    );
  }
}

/// The round's clock: red, and beating every second, for the last ten.
class _RuneClock extends StatefulWidget {
  const _RuneClock({required this.seconds, required this.urgent, required this.still});

  final int seconds;
  final bool urgent;
  final bool still;

  @override
  State<_RuneClock> createState() => _RuneClockState();
}

class _RuneClockState extends State<_RuneClock> with SingleTickerProviderStateMixin {
  late final _beat = AnimationController(vsync: this, duration: const Duration(milliseconds: 360));

  @override
  void didUpdateWidget(_RuneClock old) {
    super.didUpdateWidget(old);
    if (widget.urgent && widget.seconds != old.seconds && !widget.still) _beat.forward(from: 0);
  }

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final urgent = widget.urgent;
    final pill = Container(
      key: const ValueKey('rune-timer'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: urgent
              ? [Color.lerp(Palette.quenchRed, Colors.white, 0.2)!, Palette.quenchRed]
              : [Color.lerp(Palette.soot, Palette.ash, 0.5)!, Palette.soot],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: urgent ? Colors.white.withValues(alpha: 0.8) : Palette.molten.withValues(alpha: 0.7)),
        boxShadow: [
          BoxShadow(
            color: (urgent ? Palette.quenchRed : Palette.ember).withValues(alpha: urgent ? 0.7 : 0.3),
            blurRadius: urgent ? 14 : 8,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hourglass_bottom_rounded, size: 16, color: urgent ? Colors.white : Palette.molten),
          const SizedBox(width: 4),
          Text(runeClock(widget.seconds), style: letterStyle(18, color: urgent ? Colors.white : Palette.whiteHeat)),
        ],
      ),
    );
    return AnimatedBuilder(
      animation: _beat,
      child: pill,
      builder: (context, child) {
        if (!_beat.isAnimating) return child!;
        return Transform.scale(scale: 1 + 0.16 * sin(pi * _beat.value), child: child);
      },
    );
  }
}

/// How much of the round is left, as a bar under the top strip: it
/// burns down a step a second, turning red for the last ten.
class _TimeBar extends StatelessWidget {
  const _TimeBar({required this.session});

  final RuneSession session;

  @override
  Widget build(BuildContext context) {
    final total = session.grid?.seconds ?? 0;
    final secs = clockSeconds(session.timeLeft);
    final counting = session.countdownLeft > Duration.zero;
    final left = total <= 0 ? 0.0 : (counting ? 1.0 : (secs / total).clamp(0.0, 1.0));
    final urgent = !counting && secs <= 10;
    final color = urgent ? Palette.quenchRed : Palette.ember;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
      child: Container(
        height: 5,
        decoration: BoxDecoration(
          color: Palette.forgeBlack.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(3),
        ),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          key: const ValueKey('rune-time-bar'),
          widthFactor: left,
          heightFactor: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              gradient: LinearGradient(colors: [Color.lerp(color, Colors.white, 0.35)!, color]),
              boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)],
            ),
          ),
        ),
      ),
    );
  }
}
