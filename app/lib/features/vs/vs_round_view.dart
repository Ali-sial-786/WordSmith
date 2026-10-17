import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/sfx.dart';
import '../../game/providers.dart';
import '../../game/vs_session.dart';
import '../../net/room_client.dart';
import '../../ui/anvil/anvil_ring.dart';
import '../../ui/mold/mold_grid.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/toast_line.dart';
import '../../ui/widgets/video_bubble.dart';
import '../../ui/widgets/word_preview.dart';
import '../coop/emotes.dart';
import '../coop/room_video.dart';
import 'vs_widgets.dart';

/// A Versus round: everyone races the same puzzle on their own mold. Rivals'
/// progress shows across the top; no hints, but Turn is allowed.
class VsRoundView extends ConsumerStatefulWidget {
  const VsRoundView({
    super.key,
    required this.session,
    required this.cues,
    required this.onLeave,
    this.video = RoomVideo.none,
  });

  final VsSession session;
  final MoldCues cues;
  final VoidCallback onLeave;
  final RoomVideo video;

  @override
  ConsumerState<VsRoundView> createState() => _VsRoundViewState();
}

class _VsRoundViewState extends ConsumerState<VsRoundView> {
  final _preview = GlobalKey<WordPreviewState>();
  final _toast = GlobalKey<ToastLineState>();
  final _rng = Random();
  late List<int> _order;
  int _orderRound = -1;
  String _word = '';
  late final StreamSubscription<RoomEvent> _sub;
  late final Timer _tick;

  /// Rivals already sounded as nearly done, per round.
  final Set<String> _warned = {};
  int _warnedRound = -1;

  VsSession get _s => widget.session;
  Sfx get _sfx => ref.read(sfxProvider);

  @override
  void initState() {
    super.initState();
    _sub = _s.effects.listen(_onEffect);
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    _tick.cancel();
    super.dispose();
  }

  void _haptic(void Function() fn) {
    if (ref.read(settingsProvider).haptics) fn();
  }

  void _onEffect(RoomEvent e) {
    if (!mounted) return;
    switch (e) {
      case WordResult(:final word, :final result, :final slot, :final auto, :final pickup):
        switch (result) {
          case 'claimed':
            _preview.currentState?.react(word, PreviewResult.good);
            _sfx.play(SfxId.clang);
            _haptic(HapticFeedback.mediumImpact);
            final mold = _s.mold;
            if (mold != null && slot != null) {
              widget.cues.stagger(mold.slot(slot).cells);
              for (final (s, _) in auto) {
                widget.cues.stagger(mold.slot(s).cells);
              }
            }
            if (pickup != null) {
              _sfx.play(SfxId.pickup);
              _toast.currentState?.show('Ember found! Yours after the match', color: Palette.molten);
            }
          case 'bonus':
            _preview.currentState?.react(word, PreviewResult.bonus);
            _sfx.play(SfxId.bonus);
            _toast.currentState?.show('Bonus word! Into the Scrap Bin', color: Palette.verdigris);
          case 'already':
            _preview.currentState?.react(word, PreviewResult.repeat);
            _sfx.play(SfxId.already);
            _toast.currentState?.show('Already in your mold');
          case 'rate_limited':
            _preview.currentState?.react(word, PreviewResult.bad);
            _toast.currentState?.show('Slow down, smith!', color: Palette.quenchRed);
          case 'too_late':
            _preview.currentState?.react(word, PreviewResult.bad);
          default:
            _preview.currentState?.react(word, PreviewResult.bad);
            _sfx.play(SfxId.invalid);
        }
      case RacerProgress(:final id) when id != _s.me && e.fraction >= 0.75:
        final round = _s.round?.round ?? 0;
        if (round != _warnedRound) {
          _warned.clear();
          _warnedRound = round;
        }
        if (_warned.add(id)) {
          _sfx.play(SfxId.rivalFinished, volume: 0.7);
          _haptic(HapticFeedback.heavyImpact);
        }
      case RoomError(:final code) when code == 'not_playing':
        _toast.currentState?.show("You're watching this round", color: Palette.steel);
      default:
        break;
    }
  }

  void _onSelection(String word) {
    if (word.length > _word.length) {
      _sfx.tink(word.length);
      _haptic(HapticFeedback.selectionClick);
    }
    setState(() => _word = word);
  }

  void _onSubmit(String word) {
    if (word.length < 3) {
      _preview.currentState?.react(word, PreviewResult.bad);
      return;
    }
    _s.submit(word);
  }

  void _turn() {
    _sfx.play(SfxId.shuffle);
    setState(() {
      final next = [..._order];
      while (next.length > 1 && _sameOrder(next, _order)) {
        next.shuffle(_rng);
      }
      _order = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final round = _s.round!;
    final mold = _s.mold!;
    if (_orderRound != round.round) {
      _orderRound = round.round;
      _order = List.generate(round.letters.length, (i) => i);
    }
    final counting = _s.countdownLeft > Duration.zero;
    final left = _s.timeLeft;
    final over = _s.roundOver;
    final playing = !counting && !over && left > Duration.zero && _s.phase == 'round' && _s.racing;
    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, c) {
            final ring = min(c.maxWidth * 0.6, c.maxHeight * 0.32);
            final side = (c.maxWidth - ring) / 2;
            return Column(
              children: [
                _VsTopStrip(session: _s, timeLeft: left, onLeave: widget.onLeave, video: widget.video),
                RivalStrip(session: _s, call: widget.video.call),
                Expanded(
                  child: _s.racing
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                          child: MoldGrid(mold: mold, metal: MetalStyle.forChapter('steel'), cues: widget.cues),
                        )
                      : _Watching(session: _s),
                ),
                SizedBox(
                  height: 22,
                  child: _s.feed.isEmpty
                      ? null
                      : Text(
                          _s.feed.first.text,
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: _s.feed.first.color),
                        ),
                ),
                ToastLine(key: _toast),
                WordPreview(key: _preview, word: _word),
                SizedBox(
                  height: ring + 8,
                  child: Row(
                    children: [
                      SizedBox(
                        width: side,
                        child: Center(
                          child: RoundMetalButton(icon: 'turn', tooltip: 'Turn the tiles', onPressed: _turn),
                        ),
                      ),
                      AnvilRing(
                        letters: round.letters,
                        order: _order,
                        size: ring,
                        enabled: playing,
                        onSelectionChanged: _onSelection,
                        onSubmit: _onSubmit,
                      ),
                      SizedBox(width: side, child: _MyStatus(session: _s)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
        if (counting) Positioned.fill(child: VsCountdown(session: _s)),
        if (over && _s.standings != null)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Palette.forgeBlack.withValues(alpha: 0.55),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      roundHeadline(_s, _s.standings!),
                      textAlign: TextAlign.center,
                      style: displayStyle(30, color: Palette.molten).copyWith(
                        shadows: const [Shadow(color: Palette.ember, blurRadius: 24)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  static bool _sameOrder(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _VsTopStrip extends StatelessWidget {
  const _VsTopStrip({required this.session, required this.timeLeft, required this.onLeave, required this.video});

  final VsSession session;
  final Duration timeLeft;
  final VoidCallback onLeave;
  final RoomVideo video;

  @override
  Widget build(BuildContext context) {
    final secs = timeLeft.inSeconds;
    final urgent = secs <= 10 && secs > 0;
    final sudden = session.round?.suddenDeath ?? false;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(onPressed: onLeave, icon: const Icon(Icons.close, color: Palette.steel)),
          Expanded(
            child: Text(
              roundLabel(session),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: displayStyle(16, color: sudden ? Palette.quenchRed : Palette.whiteHeat),
            ),
          ),
          if (video.call != null) VideoToggles(call: video.call!, onCamera: video.onCamera, onMic: video.onMic, size: 20),
          EmoteButton(onEmote: session.emote, size: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: urgent ? Palette.quenchRed.withValues(alpha: 0.25) : Palette.soot,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: urgent ? Palette.quenchRed : Palette.ash),
            ),
            child: Text(
              '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}',
              style: letterStyle(18, color: urgent ? Palette.quenchRed : Palette.whiteHeat),
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
    );
  }
}

/// My letters, wins and bonus words, beside the anvil.
class _MyStatus extends StatelessWidget {
  const _MyStatus({required this.session});

  final VsSession session;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = session.colorOf(session.me);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('${session.myFilled}/${session.total}', style: displayStyle(20, color: color)),
        Text('letters', style: text.labelSmall),
        const SizedBox(height: 8),
        WinPips(wins: session.tally[session.me] ?? 0, color: color),
        if (session.bonusWords > 0) ...[
          const SizedBox(height: 8),
          Text('+${session.bonusWords} bonus', style: text.labelSmall?.copyWith(color: Palette.verdigris)),
        ],
      ],
    );
  }
}

/// Someone sitting out a sudden-death round watches the racers' bars.
class _Watching extends StatelessWidget {
  const _Watching({required this.session});

  final VsSession session;

  @override
  Widget build(BuildContext context) {
    final racers = session.round?.racers ?? const [];
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('Sudden death', style: displayStyle(26, color: Palette.quenchRed)),
          const SizedBox(height: 6),
          Text(racers.map(session.nameOf).join('  vs  '), textAlign: TextAlign.center, style: text.titleMedium),
          const SizedBox(height: 18),
          for (final id in racers)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  SizedBox(width: 90, child: Text(session.nameOf(id), overflow: TextOverflow.ellipsis)),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: session.progress[id]?.fraction ?? 0,
                        minHeight: 12,
                        color: session.colorOf(id),
                        backgroundColor: Palette.soot,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text("You're watching this one. Cheer them on!", style: text.bodySmall),
        ],
      ),
    );
  }
}
