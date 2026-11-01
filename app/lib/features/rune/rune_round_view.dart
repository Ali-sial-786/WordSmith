import 'dart:async';

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
      setState(() {});
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
            _board.currentState?.flash(path, Palette.verdigris);
            _sfx.play(SfxId.clang);
            _haptic(HapticFeedback.mediumImpact);
            _toast.currentState?.show('$word  +$points', color: Palette.verdigris);
          case 'already':
            _preview.currentState?.react(word, PreviewResult.repeat);
            _board.currentState?.flash(path, Palette.gold);
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
            _board.currentState?.flash(path, Palette.quenchRed);
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
      _board.currentState?.flash(path, Palette.quenchRed);
      _toast.currentState?.show('Words need ${_s.minLength} letters or more', color: Palette.steel);
      return;
    }
    if (_s.has(word)) {
      final by = _s.mine.firstWhere((w) => w.word == word).by;
      _preview.currentState?.react(word, PreviewResult.repeat);
      _board.currentState?.flash(path, Palette.gold);
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
    final counting = _s.countdownLeft > Duration.zero;
    final words = _s.mine.reversed.toList();
    return Stack(
      children: [
        Column(
          children: [
            _TopStrip(session: _s, onLeave: widget.onLeave, video: widget.video),
            RuneRivalStrip(session: _s, call: widget.video.call),
            if (_s.isTeam) RuneTeamBar(session: _s),
            SizedBox(
              height: 20,
              child: _s.feed.isEmpty
                  ? null
                  : Text(_s.feed.first.text, style: text.labelMedium?.copyWith(color: _s.feed.first.color)),
            ),
            WordPreview(key: _preview, word: _playing ? _word : ''),
            ToastLine(key: _toast),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: RuneBoard(
                        key: _board,
                        // Blank until the round starts: everyone sees the letters at once.
                        tiles: counting ? _blank(grid.tiles.length) : grid.tiles,
                        size: grid.size,
                        enabled: _playing,
                        quarterTurns: _turns,
                        onChanged: _onChanged,
                        onSubmit: _onSubmit,
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
                    child: Text(
                      _s.pooled
                          ? 'Your team: ${_s.mine.length} words · ${_s.myPoints} pts'
                          : '${_s.mine.length} ${_s.mine.length == 1 ? 'word' : 'words'} · ${_s.myPoints} pts',
                      key: const ValueKey('rune-mine'),
                      textAlign: TextAlign.center,
                      style: displayStyle(16, color: _s.colorOf(_s.me)),
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
                      padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
                      child: Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: [
                          for (final w in words)
                            RuneWordChip(
                              word: w.word,
                              points: w.points,
                              color: w.by == _s.me ? null : _s.colorOf(w.by),
                              onTap: () => showMeanings(context, [w.word]),
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
        if (counting) Positioned.fill(child: RuneCountdown(session: _s)),
        // The clock ran out: a moment until the server's count comes.
        if (!counting && _s.timeLeft == Duration.zero && grid.endsAt > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Palette.forgeBlack.withValues(alpha: 0.55),
                child: Center(
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
      ],
    );
  }
}

class _TopStrip extends StatelessWidget {
  const _TopStrip({required this.session, required this.onLeave, required this.video});

  final RuneSession session;
  final VoidCallback onLeave;
  final RoomVideo video;

  @override
  Widget build(BuildContext context) {
    final secs = session.timeLeft.inSeconds + (session.timeLeft.inMilliseconds % 1000 > 0 ? 1 : 0);
    final urgent = secs <= 10 && secs > 0;
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
          Container(
            key: const ValueKey('rune-timer'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: urgent ? Palette.quenchRed.withValues(alpha: 0.25) : Palette.soot,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: urgent ? Palette.quenchRed : Palette.ash),
            ),
            child: Text(
              runeClock(session.countdownLeft > Duration.zero ? g?.seconds ?? 0 : secs),
              style: letterStyle(18, color: urgent ? Palette.quenchRed : Palette.whiteHeat),
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
    );
  }
}
