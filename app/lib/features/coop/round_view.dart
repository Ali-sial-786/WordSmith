import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/sfx.dart';
import '../../engine/hints.dart';
import '../../engine/puzzle.dart';
import '../../game/coop_session.dart';
import '../../game/providers.dart';
import '../../net/room_client.dart';
import '../../ui/widgets/meaning_sheet.dart';
import '../../ui/anvil/anvil_ring.dart';
import '../../ui/mold/mold_grid.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/toast_line.dart';
import '../../ui/widgets/video_bubble.dart';
import '../../ui/widgets/word_preview.dart';
import '../../video/video_call.dart';
import 'emotes.dart';
import 'room_chat.dart';
import 'room_video.dart';

/// The co-op round: one shared mold, everyone's anvil has the same letters.
class RoundView extends ConsumerStatefulWidget {
  const RoundView({
    super.key,
    required this.session,
    required this.cues,
    required this.onLeave,
    this.video = RoomVideo.none,
  });

  final CoopSession session;
  final MoldCues cues;
  final VoidCallback onLeave;
  final RoomVideo video;

  @override
  ConsumerState<RoundView> createState() => _RoundViewState();
}

class _RoundViewState extends ConsumerState<RoundView> {
  final _preview = GlobalKey<WordPreviewState>();
  final _toast = GlobalKey<ToastLineState>();
  final _rng = Random();
  late List<int> _order;
  int _orderRound = -1;
  String _word = '';
  bool _chisel = false;
  late final StreamSubscription<RoomEvent> _sub;
  late final Timer _tick;

  CoopSession get _s => widget.session;
  Sfx get _sfx => ref.read(sfxProvider);

  @override
  void initState() {
    super.initState();
    _sub = _s.effects.listen(_onEffect);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) HammerStrike.precache(context);
    });
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
      case WordResult(:final word, :final result, :final by):
        switch (result) {
          case 'claimed':
            _preview.currentState?.react(word, PreviewResult.good);
            _sfx.play(SfxId.clang);
            _haptic(HapticFeedback.mediumImpact);
          case 'bonus':
            _preview.currentState?.react(word, PreviewResult.bonus);
            _sfx.play(SfxId.bonus);
            _toast.currentState?.show('Bonus word!', color: Palette.verdigris);
          case 'already':
            _preview.currentState?.react(word, PreviewResult.repeat);
            _sfx.play(SfxId.already);
            _toast.currentState?.show(by == null ? 'Already in the mold' : 'Already forged by ${_s.nameOf(by)}');
          case 'rate_limited':
            _preview.currentState?.react(word, PreviewResult.bad);
            _toast.currentState?.show('Slow down, smith!', color: Palette.quenchRed);
          case 'too_late':
            _preview.currentState?.react(word, PreviewResult.bad);
            _toast.currentState?.show("Time's up!");
          default:
            _preview.currentState?.react(word, PreviewResult.bad);
            _sfx.play(SfxId.invalid);
        }
      case WordClaimed(:final slot, :final by, :final auto, :final pickup):
        widget.cues.stagger(_s.mold!.slot(slot).cells);
        for (final (s, _) in auto) {
          widget.cues.stagger(_s.mold!.slot(s).cells);
        }
        if (by != _s.me) _sfx.play(SfxId.clangLight);
        if (pickup != null && by == _s.me) {
          final kind = HintKind.byName(pickup);
          ref.read(profileProvider.notifier).addHint(kind);
          _sfx.play(SfxId.pickup);
          _toast.currentState?.show('Ember found! +1 ${kind.title}', color: Palette.molten);
        }
      case Revealed(:final by, :final kind, :final cells, :final auto) when kind == 'hammer' && cells.length == 1:
        // Whoever used it, everyone sees the hammer swing down.
        widget.cues.strike(cells.single.$1, completed: [for (final (s, _) in auto) _s.mold!.slot(s).cells]);
        _sfx.hammerStrike(hammerImpact);
        Future.delayed(hammerImpact, () => _haptic(HapticFeedback.mediumImpact));
        if (by == _s.me) ref.read(profileProvider.notifier).addHint(HintKind.hammer, -1);
      case Revealed(:final by, :final kind, :final auto):
        _sfx.play(
          kind == 'sparks'
              ? SfxId.hintSparks
              : kind == 'chisel'
              ? SfxId.hintChisel
              : SfxId.hintHammer,
        );
        for (final (s, _) in auto) {
          widget.cues.stagger(_s.mold!.slot(s).cells);
        }
        if (by == _s.me) ref.read(profileProvider.notifier).addHint(HintKind.byName(kind), -1);
      case HeatedSlot(:final saved) when saved > 0 && !_s.melting:
        _toast.currentState?.show('Saved! The next word is heating up', color: Palette.molten);
      case Melted():
        setState(() => _chisel = false);
        _sfx.play(SfxId.melt);
        _haptic(HapticFeedback.heavyImpact);
      case RoomError(:final code):
        final message = switch (code) {
          'no_hint' => 'No hints of that kind left.',
          'hint_locked' => 'That hint is still locked.',
          _ => null,
        };
        if (message != null) _toast.currentState?.show(message, color: Palette.steel);
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

  void _useHint(HintKind kind) {
    final profile = ref.read(profileProvider);
    if (!kind.unlockedAt(profile.level)) {
      _toast.currentState?.show('${kind.title} unlocks at Smith Level ${kind.unlockLevel}');
      return;
    }
    if (profile.hintCount(kind) <= 0) {
      _toast.currentState?.show('No ${kind.title}s left', color: Palette.steel);
      return;
    }
    if (kind == HintKind.chisel) {
      setState(() => _chisel = !_chisel);
      if (_chisel) _toast.currentState?.show('Tap a cell to chisel its letter');
      return;
    }
    _s.hint(kind.name);
  }

  void _onChiselCell(CellPos cell) {
    setState(() => _chisel = false);
    _s.hint('chisel', cell: cell);
  }

  @override
  Widget build(BuildContext context) {
    final leftHanded = ref.watch(settingsProvider.select((s) => s.leftHanded));
    final round = _s.round!;
    final mold = _s.mold!;
    if (_orderRound != round.round) {
      _orderRound = round.round;
      _order = List.generate(round.letters.length, (i) => i);
    }
    final profile = ref.watch(profileProvider);
    final counting = _s.countdownLeft > Duration.zero;
    final left = _s.timeLeft;
    final playing = !counting && left > Duration.zero && _s.phase == 'round' && _s.melt == null;
    final heated = _s.heated;
    final heat = !_s.survival || heated == null || counting
        ? null
        : HeatView(
            cells: mold.slot(heated.slot).cells,
            remainingMs: () => _s.heatRemainingMs,
            durationMs: heated.durationMs,
            onSecond: (_) => _sfx.play(SfxId.tick, volume: 0.7),
          );
    final melt = _s.melt;
    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, c) {
            final ring = min(c.maxWidth * 0.62, c.maxHeight * 0.34);
            final side = (c.maxWidth - ring) / 2;
            return Column(
              children: [
                _TopStrip(session: _s, timeLeft: left, onLeave: widget.onLeave, video: widget.video),
                _Teammates(session: _s, call: widget.video.call),
                if (_s.survival)
                  HeatBar(
                    heat: heat,
                    idle: melt != null
                        ? 'Melted! The round is over'
                        : counting
                        ? 'Survival: forge the heated word before it melts'
                        : 'Heating the next word…',
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                    child: MoldGrid(
                      mold: mold,
                      metal: MetalStyle.forChapter('iron'),
                      cues: widget.cues,
                      chiselMode: _chisel,
                      onCellTap: _onChiselCell,
                      onFilledTap: (c) => showMeanings(context, mold.wordsAt(c)),
                      heat: heat,
                      melt: melt == null
                          ? null
                          : MeltView(
                              cells: [
                                for (final c in mold.slot(melt.slot).cells)
                                  if (mold.fillOf(c) != CellFill.filled) c,
                              ],
                              id: '${round.round}-${melt.slot}',
                            ),
                      reducedMotion: ref.watch(settingsProvider.select((s) => s.reducedMotion)),
                    ),
                  ),
                ),
                SizedBox(
                  height: 54,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      for (final line in _s.feed.take(2))
                        Text(line.text, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: line.color)),
                    ],
                  ),
                ),
                ToastLine(key: _toast),
                WordPreview(key: _preview, word: _word),
                SizedBox(
                  height: ring + 8,
                  child: Row(
                    // Left-handed: Turn on the right, hints or status on the left.
                    textDirection: leftHanded ? TextDirection.rtl : TextDirection.ltr,
                    children: [
                      SizedBox(
                        width: side,
                        child: Center(
                          child: RoundMetalButton(
                            icon: 'turn',
                            tooltip: 'Turn the tiles',
                            onPressed: () {
                              _sfx.play(SfxId.shuffle);
                              setState(() {
                                final next = [..._order];
                                while (next.length > 1 && _sameOrder(next, _order)) {
                                  next.shuffle(_rng);
                                }
                                _order = next;
                              });
                            },
                          ),
                        ),
                      ),
                      AnvilRing(
                        letters: round.letters,
                        order: _order,
                        size: ring,
                        enabled: playing && !_chisel,
                        onSelectionChanged: _onSelection,
                        onSubmit: _onSubmit,
                      ),
                      SizedBox(
                        width: side,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            for (final kind in HintKind.values)
                              RoundMetalButton(
                                icon: kind.name,
                                size: 48,
                                locked: !kind.unlockedAt(profile.level),
                                active: kind == HintKind.chisel && _chisel,
                                badge: kind.unlockedAt(profile.level)
                                    ? '${profile.hintCount(kind)}'
                                    : 'Lv${kind.unlockLevel}',
                                tooltip: kind.title,
                                onPressed: playing ? () => _useHint(kind) : null,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
        if (counting)
          Positioned.fill(
            child: ColoredBox(
              color: Palette.forgeBlack.withValues(alpha: 0.6),
              child: Center(
                child: Text(
                  '${_s.countdownLeft.inSeconds + 1}',
                  style: displayStyle(
                    110,
                    color: Palette.molten,
                  ).copyWith(shadows: [Shadow(color: Palette.ember, blurRadius: 40)]),
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

class _TopStrip extends StatelessWidget {
  const _TopStrip({required this.session, required this.timeLeft, required this.onLeave, required this.video});

  final CoopSession session;
  final Duration timeLeft;
  final VoidCallback onLeave;
  final RoomVideo video;

  @override
  Widget build(BuildContext context) {
    final team = session.scores.values.fold<int>(0, (a, b) => a + b);
    final secs = timeLeft.inSeconds;
    final urgent = secs <= 10 && secs > 0 && !session.survival;
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            onPressed: onLeave,
            icon: Icon(Icons.close, color: Palette.steel),
          ),
          Expanded(
            child: Text('Team $team', maxLines: 1, overflow: TextOverflow.ellipsis, style: displayStyle(18)),
          ),
          if (video.call != null)
            VideoToggles(call: video.call!, onCamera: video.onCamera, onMic: video.onMic, size: 20),
          ChatButton(session: session, size: 20),
          EmoteButton(onEmote: session.emote, size: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: urgent ? Palette.quenchRed.withValues(alpha: 0.25) : Palette.soot,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: urgent ? Palette.quenchRed : Palette.ash),
            ),
            child: Text(
              // Survival has no round clock: the heated word is the clock.
              session.survival ? 'Saved ${session.saved}' : '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}',
              style: letterStyle(20, color: urgent ? Palette.quenchRed : Palette.whiteHeat),
            ),
          ),
          const SizedBox(width: 14),
        ],
      ),
    );
  }
}

class _Teammates extends StatelessWidget {
  const _Teammates({required this.session, this.call});

  final CoopSession session;
  final VideoCall? call;

  @override
  Widget build(BuildContext context) {
    final players = session.lobby?.players ?? const [];
    final text = Theme.of(context).textTheme;
    return SizedBox(
      height: call == null ? 46 : 58,
      // Shrinks a little rather than overflow (four smiths, big scores, video).
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final p in players)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.fromLTRB(4, 3, 10, 3),
                decoration: BoxDecoration(
                  color: Palette.soot.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Palette.player(p.color), width: 2),
                ),
                child: Row(
                  children: [
                    VideoBubble(
                      userId: p.id,
                      avatar: p.avatar,
                      size: call == null ? 30 : 42,
                      call: call,
                      color: Palette.player(p.color),
                      dimmed: !p.connected,
                      me: p.id == session.me,
                    ),
                    const SizedBox(width: 6),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // With video on, which bubble is mine.
                        if (call != null && p.id == session.me)
                          Text('You', style: text.labelSmall?.copyWith(color: Palette.player(p.color), height: 1)),
                        Text('${session.scores[p.id] ?? 0}', style: text.labelLarge),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
