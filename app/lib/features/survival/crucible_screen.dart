import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/sfx.dart';
import '../../engine/board.dart';
import '../../engine/hints.dart';
import '../../engine/puzzle.dart';
import '../../game/account.dart';
import '../../game/history_records.dart';
import '../../game/providers.dart';
import '../../game/survival_run.dart';
import '../../net/models.dart';
import '../../ui/anvil/anvil_ring.dart';
import '../../ui/effects/sparks.dart';
import '../../ui/mold/mold_grid.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/forge_frame.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/meaning_sheet.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/toast_line.dart';
import '../../ui/widgets/word_preview.dart';

/// The Crucible: solo Survival. Puzzle after puzzle with a heated word on a
/// countdown; the run ends when one melts.
class CrucibleScreen extends ConsumerStatefulWidget {
  const CrucibleScreen({super.key});

  @override
  ConsumerState<CrucibleScreen> createState() => _CrucibleScreenState();
}

class _CrucibleScreenState extends ConsumerState<CrucibleScreen> with WidgetsBindingObserver {
  late SurvivalRun _run;
  final _cues = MoldCues();
  final _preview = GlobalKey<WordPreviewState>();
  final _toast = GlobalKey<ToastLineState>();
  final _moldKey = GlobalKey();
  String _word = '';
  bool _chisel = false;
  CrucibleStage _shown = CrucibleStage.playing;
  int _shownPuzzle = 1;
  Slot? _shownHeat;
  late final Sfx _sfx;
  late final AccountController _account;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sfx = ref.read(sfxProvider);
    _account = ref.read(accountProvider.notifier)..setStatus('solo');
    _run = _newRun();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) HammerStrike.precache(context);
      final store = ref.read(storeProvider);
      if (!mounted || store.seenTip('crucible')) return;
      store.markTip('crucible');
      _toast.currentState?.show('Forge the glowing word before its timer runs out!', color: Palette.molten);
    });
  }

  SurvivalRun _newRun() {
    // Read now: a run can end as the screen is disposed, when ref is gone.
    final history = ref.read(historyProvider.notifier);
    return SurvivalRun(
      campaign: ref.read(campaignProvider),
      store: ref.read(storeProvider),
      profile: ref.read(profileProvider.notifier),
      furthestStage: ref.read(profileProvider).campaignStage - 1,
      onFinished: (run) => history.add(crucibleRecord(run, at: DateTime.now().millisecondsSinceEpoch)),
    )..addListener(_onRunChanged);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _run.resume();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _run.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _account.setStatus('online');
    // Leaving mid-run ends it; its result is queued for the next sync.
    _run.finish();
    _run
      ..removeListener(_onRunChanged)
      ..dispose();
    super.dispose();
  }

  void _haptic(void Function() fn) {
    if (ref.read(settingsProvider).haptics) fn();
  }

  void _onRunChanged() {
    if (!mounted) return;
    final r = _run;
    if (r.heated != _shownHeat && r.stage == CrucibleStage.playing) {
      // A saved word: the next one heats up.
      if (_shownHeat != null && r.heated != null && r.number == _shownPuzzle) {
        _toast.currentState?.show('Saved! The next word is heating up', color: Palette.molten);
      }
      _shownHeat = r.heated;
    }
    if (r.stage != _shown || r.number != _shownPuzzle) {
      if (r.stage == CrucibleStage.cleared) _onCleared();
      if (r.stage == CrucibleStage.melted) _onMelted();
      if (r.stage == CrucibleStage.playing && r.number != _shownPuzzle) {
        _cues.clear();
        _toast.currentState?.show('Puzzle ${r.number}: the next mold is heating', color: Palette.molten);
      }
      _shown = r.stage;
      _shownPuzzle = r.number;
    }
    setState(() {});
  }

  void _onCleared() {
    _sfx.play(SfxId.forged);
    _haptic(HapticFeedback.heavyImpact);
    for (var i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: i * 140), () => _burstAt(_moldKey));
    }
    _toast.currentState?.show('Forged! ${_run.cleared} cleared', color: Palette.gold);
  }

  Future<void> _onMelted() async {
    setState(() => _chisel = false);
    _sfx.play(SfxId.melt);
    _haptic(HapticFeedback.heavyImpact);
    final report = _run.finish();
    final result = report == null ? null : _account.sendSurvival(report);
    await Future<void>.delayed(meltDuration + const Duration(milliseconds: 300));
    if (!mounted) return;
    final again = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _RunOver(run: _run, result: result, localBest: _localBest()),
    );
    if (!mounted) return;
    if (again == true) {
      setState(() {
        _run.removeListener(_onRunChanged);
        _run.dispose();
        _run = _newRun();
        _shown = CrucibleStage.playing;
        _shownPuzzle = 1;
        _shownHeat = null;
        _cues.clear();
      });
    } else {
      context.canPop() ? context.pop() : context.go('/');
    }
  }

  /// Keeps this phone's best run and returns the one before this.
  SurvivalBest? _localBest() {
    final store = ref.read(storeProvider);
    final raw = store.loadSurvivalBest();
    final before = raw == null ? null : SurvivalBest.fromJson(raw);
    final now = SurvivalBest(
      puzzles: _run.cleared,
      words: _run.words,
      saved: _run.saved,
      at: DateTime.now().millisecondsSinceEpoch,
    );
    if (now.beats(before)) store.saveSurvivalBest(now.toJson());
    return before;
  }

  void _onSelection(String word) {
    if (word.length > _word.length) {
      _sfx.tink(word.length);
      _haptic(HapticFeedback.selectionClick);
    }
    setState(() => _word = word);
  }

  void _onSubmit(String word) {
    if (_run.stage != CrucibleStage.playing) return;
    if (word.length < 3) {
      _preview.currentState?.react(word, PreviewResult.bad);
      return;
    }
    final r = _run.submit(word);
    switch (r.outcome) {
      case SubmitOutcome.found:
        for (final s in r.completedSlots) {
          _cues.stagger(s.cells);
        }
        _preview.currentState?.react(r.word, PreviewResult.good);
        _sfx.play(SfxId.clang);
        _haptic(HapticFeedback.mediumImpact);
      case SubmitOutcome.bonus:
        _preview.currentState?.react(r.word, PreviewResult.bonus);
        _sfx.play(SfxId.bonus);
        _toast.currentState?.show('Bonus word! (no Scrap Bin in the Crucible)', color: Palette.verdigris);
      case SubmitOutcome.alreadyFound || SubmitOutcome.alreadyBonus:
        if (r.slot != null) _cues.pulse(r.slot!.cells);
        _preview.currentState?.react(r.word, PreviewResult.repeat);
        _sfx.play(SfxId.already);
      case SubmitOutcome.invalid || SubmitOutcome.tooShort:
        _preview.currentState?.react(r.word, PreviewResult.bad);
        _sfx.play(SfxId.invalid);
        _haptic(HapticFeedback.lightImpact);
    }
  }

  void _useHint(HintKind kind) {
    final level = ref.read(profileProvider).level;
    if (!kind.unlockedAt(level)) {
      _toast.currentState?.show('${kind.title} unlocks at Smith Level ${kind.unlockLevel}');
      return;
    }
    if (!_run.canUse(kind)) {
      _toast.currentState?.show('No ${kind.title}s left', color: Palette.steel);
      return;
    }
    switch (kind) {
      case HintKind.hammer:
        final r = _run.useHammer();
        if (r == null) return;
        // The hammer swings down; the letter shows as it lands.
        _cues.strike(r.cells.single, completed: [for (final s in r.completedSlots) s.cells]);
        _sfx.hammerStrike(hammerImpact);
        Future.delayed(hammerImpact, () => _haptic(HapticFeedback.heavyImpact));
      case HintKind.chisel:
        setState(() => _chisel = !_chisel);
        if (_chisel) _toast.currentState?.show('Tap a cell to chisel its letter');
      case HintKind.sparks:
        _afterReveal(_run.useSparks(), SfxId.hintSparks);
    }
  }

  void _afterReveal(RevealResult? r, SfxId sound) {
    if (r == null) return;
    _sfx.play(sound);
    _haptic(HapticFeedback.mediumImpact);
    for (final s in r.completedSlots) {
      _cues.stagger(s.cells);
    }
  }

  void _burstAt(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    SparkField.of(key.currentContext!)
        ?.burst(box.localToGlobal(box.size.center(Offset.zero)), count: 30, speed: 320, spread: pi * 2);
  }

  Future<void> _leave() async {
    if (_run.over || (_run.number == 1 && _run.board.foundSlots.isEmpty)) {
      context.canPop() ? context.pop() : context.go('/');
      return;
    }
    _run.pause();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave the Crucible?'),
        content: const Text('Your run ends here. What you forged still counts.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep going')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Leave')),
        ],
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      if (_run.finish() != null) _account.sync();
      if (mounted) context.canPop() ? context.pop() : context.go('/');
    } else {
      _run.resume();
    }
  }

  HeatView? get _heat {
    final slot = _run.heated;
    if (slot == null || _run.stage != CrucibleStage.playing) return null;
    return HeatView(
      cells: slot.cells,
      remainingMs: () => _run.remainingMs,
      durationMs: _run.heatDurationMs,
      onSecond: (_) => _sfx.play(SfxId.tick, volume: 0.7),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider);
    final reducedMotion = ref.watch(settingsProvider.select((s) => s.reducedMotion));
    final leftHanded = ref.watch(settingsProvider.select((s) => s.leftHanded));
    final run = _run;
    final look = ref.read(campaignProvider).chapterFor(run.puzzleStage).id;
    final playing = run.stage == CrucibleStage.playing;
    final heat = _heat;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        body: ForgeBackground(
          image: chapterBackground(look),
          warmth: chapterWarmth(look),
          fire: 1,
          fireHeight: 0.5,
          child: SparkField(
            intensity: reducedMotion ? 0.35 : 1,
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, c) {
                  final ring = min(c.maxWidth * 0.64, c.maxHeight * 0.36);
                  final side = (c.maxWidth - ring) / 2;
                  final tools = SizedBox(
                    width: side,
                    child: Center(
                      child: RoundMetalButton(
                        icon: 'turn',
                        tooltip: 'Turn the tiles',
                        onPressed: playing
                            ? () {
                                _sfx.play(SfxId.shuffle);
                                run.turn();
                              }
                            : null,
                      ),
                    ),
                  );
                  final hints = SizedBox(
                    width: side,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (final kind in HintKind.values)
                          RoundMetalButton(
                            icon: kind.name,
                            size: 50,
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
                  );
                  return Column(
                    children: [
                      _TopBar(run: run, onLeave: _leave),
                      HeatBar(
                        heat: heat,
                        idle: run.stage == CrucibleStage.melted
                            ? 'Melted!'
                            : run.stage == CrucibleStage.cleared
                            ? 'Forged! The next mold is coming…'
                            : 'Heating the next word…',
                        trailing: Text('Saved ${run.saved}', style: Theme.of(context).textTheme.labelLarge),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
                          child: KeyedSubtree(
                            key: _moldKey,
                            child: MoldGrid(
                              key: ValueKey('${run.runId}-${run.number}'),
                              mold: BoardMold(run.board),
                              metal: MetalStyle.forChapter(look),
                              cues: _cues,
                              chiselMode: _chisel,
                              onCellTap: (cell) {
                                setState(() => _chisel = false);
                                _afterReveal(run.useChisel(cell), SfxId.hintChisel);
                              },
                              onFilledTap: (cell) => showMeanings(context, [
                                for (final s in run.puzzle.slotsAt[cell] ?? const <Slot>[])
                                  if (run.board.isSlotComplete(s)) s.word,
                              ]),
                              heat: heat,
                              melt: run.stage == CrucibleStage.melted
                                  ? MeltView(cells: run.meltedCells, id: '${run.runId}-${run.number}')
                                  : null,
                              reducedMotion: reducedMotion,
                            ),
                          ),
                        ),
                      ),
                      ToastLine(key: _toast),
                      WordPreview(key: _preview, word: _word),
                      SizedBox(
                        height: ring + 8,
                        child: Row(
                          children: [
                            if (leftHanded) hints else tools,
                            AnvilRing(
                              letters: run.letters,
                              order: run.order,
                              size: ring,
                              enabled: playing && !_chisel,
                              onSelectionChanged: _onSelection,
                              onSubmit: _onSubmit,
                            ),
                            if (leftHanded) tools else hints,
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.run, required this.onLeave});

  final SurvivalRun run;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 56,
    child: Row(
      children: [
        IconButton(tooltip: 'Leave', onPressed: onLeave, icon: const GameIcon('back', size: 26)),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('The Crucible', style: displayStyle(19)),
              Text(
                'Puzzle ${run.number} · ${run.cleared} cleared · ${run.words} words',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: 48),
      ],
    ),
  );
}

/// The end of a run: how far it got, the best run, and the XP once the
/// server has counted it.
class _RunOver extends StatelessWidget {
  const _RunOver({required this.run, required this.result, required this.localBest});

  final SurvivalRun run;
  final Future<SurvivalOutcome?>? result;
  final SurvivalBest? localBest;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final mine = SurvivalBest(puzzles: run.cleared, words: run.words, saved: run.saved);
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ForgePanel(
        gold: true,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GameIcon('ember', size: 44, color: Palette.quenchRed),
            const SizedBox(height: 6),
            Text('It melted!', style: displayStyle(26, color: Palette.molten)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _Stat(value: run.cleared, label: 'cleared'),
                _Stat(value: run.words, label: 'words'),
                _Stat(value: run.saved, label: 'saved'),
              ],
            ),
            const SizedBox(height: 12),
            FutureBuilder<SurvivalOutcome?>(
              future: result,
              builder: (context, snap) {
                final out = snap.data;
                final best = out?.best ?? localBest;
                final newBest = out?.newBest ?? mine.beats(localBest);
                final lines = <String>[
                  if (newBest)
                    'A new best run!'
                  else if (best != null)
                    'Best: ${best.puzzles} cleared, ${best.words} words',
                  if (result == null)
                    'Nothing forged, so nothing to count.'
                  else if (snap.connectionState != ConnectionState.done)
                    'Counting your XP…'
                  else if (out == null)
                    'Your XP will be added when you are online.'
                  else
                    '+${out.xp} XP${out.levelUps > 0 ? ' · Level ${out.level}!' : ''}',
                ];
                return Column(
                  children: [
                    for (final l in lines)
                      Text(
                        l,
                        textAlign: TextAlign.center,
                        style: text.titleSmall?.copyWith(color: l.startsWith('A new') ? Palette.gold : null),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            PlateButton(
              label: 'Again',
              icon: 'flame',
              primary: true,
              height: 50,
              onPressed: () => Navigator.pop(context, true),
            ),
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Forge Hall')),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('$value', style: displayStyle(28)),
      Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Palette.steel)),
    ],
  );
}
