import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/sfx.dart';
import '../../engine/board.dart';
import '../../engine/hints.dart';
import '../../engine/pickups.dart';
import '../../engine/puzzle.dart';
import '../../game/providers.dart';
import '../../game/solo_controller.dart';
import '../../ui/anvil/anvil_ring.dart';
import '../../ui/effects/sparks.dart';
import '../../ui/mold/mold_grid.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/toast_line.dart';
import '../../ui/widgets/word_preview.dart';
import 'forged_overlay.dart';

class PuzzleScreen extends ConsumerStatefulWidget {
  const PuzzleScreen({super.key, required this.stage});

  final int stage;

  @override
  ConsumerState<PuzzleScreen> createState() => _PuzzleScreenState();
}

class _PuzzleScreenState extends ConsumerState<PuzzleScreen>
    with WidgetsBindingObserver {
  late final SoloController _game;
  final _cues = MoldCues();
  final _preview = GlobalKey<WordPreviewState>();
  final _toast = GlobalKey<ToastLineState>();
  final _moldKey = GlobalKey();
  final _scrapKey = GlobalKey();
  String _word = '';
  bool _chisel = false;
  bool _finishing = false;

  Sfx get _sfx => ref.read(sfxProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _game = SoloController(
      stage: widget.stage,
      campaign: ref.read(campaignProvider),
      store: ref.read(storeProvider),
      profile: ref.read(profileProvider.notifier),
    )..addListener(_onGameChanged);
    if (_game.isComplete) _finish();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _game.pause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _game
      ..pause()
      ..removeListener(_onGameChanged)
      ..dispose();
    super.dispose();
  }

  void _onGameChanged() => setState(() {});

  void _haptic(void Function() fn) {
    if (ref.read(settingsProvider).haptics) fn();
  }

  void _onSelection(String word) {
    if (word.length > _word.length) {
      _sfx.tink(word.length);
      _haptic(HapticFeedback.selectionClick);
    }
    setState(() => _word = word);
  }

  void _onSubmit(String word) {
    if (_finishing) return;
    if (word.length < 3) {
      _preview.currentState?.react(word, PreviewResult.bad);
      return;
    }
    final fb = _game.submit(word);
    final r = fb.result;
    switch (r.outcome) {
      case SubmitOutcome.found:
        for (final s in r.completedSlots) {
          _cues.stagger(s.cells);
        }
        _preview.currentState?.react(r.word, PreviewResult.good);
        _sfx.play(SfxId.clang);
        _haptic(HapticFeedback.mediumImpact);
        _announcePickups(r.collected);
      case SubmitOutcome.bonus:
        _preview.currentState?.react(r.word, PreviewResult.bonus);
        _sfx.play(SfxId.bonus);
        _haptic(HapticFeedback.lightImpact);
        _burstAt(_scrapKey, small: true);
        final bin = ref.read(profileProvider).scrapBin;
        if (fb.smelted) {
          Future.delayed(const Duration(milliseconds: 350), () {
            _sfx.play(SfxId.pickup);
            _burstAt(_scrapKey);
          });
          _toast.currentState?.show(
            'Scrap Bin smelted: +1 Hammer Strike!',
            color: Palette.molten,
          );
        } else {
          _toast.currentState?.show(
            'Bonus word! Scrap Bin $bin/$scrapBinCapacity',
            color: Palette.verdigris,
          );
        }
      case SubmitOutcome.alreadyFound:
        _cues.pulse(r.slot!.cells);
        _preview.currentState?.react(r.word, PreviewResult.repeat);
        _sfx.play(SfxId.already);
        _toast.currentState?.show('Already forged');
      case SubmitOutcome.alreadyBonus:
        _preview.currentState?.react(r.word, PreviewResult.repeat);
        _sfx.play(SfxId.already);
        _toast.currentState?.show('Already in the Scrap Bin');
      case SubmitOutcome.invalid:
      case SubmitOutcome.tooShort:
        _preview.currentState?.react(r.word, PreviewResult.bad);
        _sfx.play(SfxId.invalid);
        _haptic(HapticFeedback.lightImpact);
    }
    if (_game.isComplete) _finish();
  }

  void _announcePickups(List<Pickup> pickups) {
    if (pickups.isEmpty) return;
    Future.delayed(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      _sfx.play(SfxId.pickup);
      final names = pickups.map((p) => '+1 ${p.kind.title}').join(', ');
      _toast.currentState?.show('Ember found! $names', color: Palette.molten);
    });
  }

  void _afterReveal(RevealResult? r, SfxId sound) {
    if (r == null) return;
    _sfx.play(sound);
    _haptic(HapticFeedback.mediumImpact);
    for (final s in r.completedSlots) {
      _cues.stagger(s.cells);
    }
    _announcePickups(r.collected);
    if (_game.isComplete) _finish();
  }

  void _useHint(HintKind kind) {
    if (_finishing) return;
    final level = ref.read(profileProvider).level;
    if (!kind.unlockedAt(level)) {
      _toast.currentState?.show('${kind.title} unlocks at Smith Level ${kind.unlockLevel}');
      return;
    }
    if (!_game.canUse(kind)) {
      _toast.currentState?.show(
        'No ${kind.title}s left: level up or find embers',
        color: Palette.steel,
      );
      return;
    }
    switch (kind) {
      case HintKind.hammer:
        _afterReveal(_game.useHammer(), SfxId.hintHammer);
      case HintKind.chisel:
        setState(() => _chisel = !_chisel);
        if (_chisel) _toast.currentState?.show('Tap a cell to chisel its letter');
      case HintKind.sparks:
        _afterReveal(_game.useSparks(), SfxId.hintSparks);
    }
  }

  void _onChiselCell(CellPos cell) {
    setState(() => _chisel = false);
    _afterReveal(_game.useChisel(cell), SfxId.hintChisel);
  }

  void _turn() {
    _sfx.play(SfxId.shuffle);
    _game.turn();
  }

  void _burstAt(GlobalKey key, {bool small = false}) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    SparkField.of(key.currentContext!)?.burst(
      box.localToGlobal(box.size.center(Offset.zero)),
      count: small ? 10 : 30,
      speed: small ? 160 : 320,
      spread: pi * 2,
    );
  }

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() {
      _finishing = true;
      _chisel = false;
    });
    final reward = _game.reward;
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    if (!mounted) return;
    _sfx.play(SfxId.forged);
    _haptic(HapticFeedback.heavyImpact);
    for (var i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: i * 140), () => _burstAt(_moldKey));
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted || reward == null) return;
    if (reward.leveledUp) {
      Future.delayed(const Duration(milliseconds: 900), () => _sfx.play(SfxId.levelUp));
    }
    final campaign = ref.read(campaignProvider);
    final next = widget.stage + 1;
    final action = await showForgedOverlay(
      context,
      reward: reward,
      chapter: _game.chapter,
      nextChapter: next <= campaign.stageCount ? campaign.chapterFor(next) : null,
      pickups: [
        for (final i in _game.board.collectedPickups) _game.board.pickups[i],
      ],
      bonusWords: _game.board.bonusFound.length,
    );
    if (!mounted) return;
    if (action == ForgedAction.next && next <= campaign.stageCount) {
      context.pushReplacement('/play/$next');
    } else {
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider);
    final reducedMotion = ref.watch(settingsProvider.select((s) => s.reducedMotion));
    final chapter = _game.chapter;
    final metal = MetalStyle.forChapter(chapter.id);
    return Scaffold(
      body: ForgeBackground(
        image: 'assets/images/bg_${chapter.id}.webp',
        child: SparkField(
          intensity: reducedMotion ? 0.35 : 1,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, c) {
                final ring = min(c.maxWidth * 0.64, c.maxHeight * 0.37);
                final side = (c.maxWidth - ring) / 2;
                return Column(
                  children: [
                    _TopBar(
                      title: chapter.name,
                      subtitle: 'Puzzle ${_game.stageInChapter} of ${chapter.count}',
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
                        child: KeyedSubtree(
                          key: _moldKey,
                          child: MoldGrid(
                            board: _game.board,
                            metal: metal,
                            cues: _cues,
                            chiselMode: _chisel,
                            onCellTap: _onChiselCell,
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
                          SizedBox(
                            width: side,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                KeyedSubtree(
                                  key: _scrapKey,
                                  child: _ScrapBin(
                                    count: profile.scrapBin,
                                    words: _game.board.bonusFound,
                                  ),
                                ),
                                RoundMetalButton(
                                  icon: 'turn',
                                  tooltip: 'Turn the tiles',
                                  onPressed: _finishing ? null : _turn,
                                ),
                              ],
                            ),
                          ),
                          AnvilRing(
                            letters: _game.letters,
                            order: _game.order,
                            size: ring,
                            enabled: !_finishing && !_chisel,
                            onSelectionChanged: _onSelection,
                            onSubmit: _onSubmit,
                          ),
                          SizedBox(
                            width: side,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                for (final kind in HintKind.values)
                                  _HintButton(
                                    kind: kind,
                                    count: profile.hintCount(kind),
                                    unlocked: kind.unlockedAt(profile.level),
                                    active: kind == HintKind.chisel && _chisel,
                                    onPressed: _finishing ? null : () => _useHint(kind),
                                  ),
                              ],
                            ),
                          ),
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
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Forge Hall',
            onPressed: () => context.canPop() ? context.pop() : context.go('/'),
            icon: const GameIcon('back', size: 26),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(title, style: displayStyle(20)),
                Text(subtitle, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
            icon: const GameIcon('settings', size: 24, color: Palette.steel),
          ),
        ],
      ),
    );
  }
}

class _HintButton extends StatelessWidget {
  const _HintButton({
    required this.kind,
    required this.count,
    required this.unlocked,
    required this.active,
    required this.onPressed,
  });

  final HintKind kind;
  final int count;
  final bool unlocked;
  final bool active;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RoundMetalButton(
          icon: kind.name,
          size: 50,
          locked: !unlocked,
          active: active,
          badge: unlocked ? '$count' : 'Lv${kind.unlockLevel}',
          tooltip: kind.title,
          onPressed: onPressed,
        ),
      ],
    );
  }
}

class _ScrapBin extends StatelessWidget {
  const _ScrapBin({required this.count, required this.words});

  final int count;
  final Set<String> words;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showModalBottomSheet<void>(
        context: context,
        backgroundColor: Palette.soot,
        builder: (context) => _ScrapSheet(count: count, words: words),
      ),
      child: SizedBox.square(
        dimension: 58,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.square(
              dimension: 58,
              child: CircularProgressIndicator(
                value: count / scrapBinCapacity,
                strokeWidth: 4,
                backgroundColor: Palette.ash,
                color: Palette.verdigris,
              ),
            ),
            const GameIcon('scrap_bucket', size: 28, color: Palette.steel),
            Positioned(
              bottom: 2,
              child: Text(
                '$count/$scrapBinCapacity',
                style: const TextStyle(
                  fontFamily: Fonts.ui,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  color: Palette.whiteHeat,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScrapSheet extends StatelessWidget {
  const _ScrapSheet({required this.count, required this.words});

  final int count;
  final Set<String> words;

  @override
  Widget build(BuildContext context) {
    final sorted = words.toList()..sort();
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Scrap Bin', style: displayStyle(22)),
          const SizedBox(height: 6),
          Text(
            'Real words that aren\'t in the mold land here. Every '
            '$scrapBinCapacity are smelted into a Hammer Strike. '
            '($count/$scrapBinCapacity so far.)',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 16),
          Text('Found in this puzzle', style: text.titleSmall),
          const SizedBox(height: 8),
          if (sorted.isEmpty)
            Text('None yet.', style: text.bodySmall)
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final w in sorted)
                  Chip(
                    label: Text(w, style: letterStyle(14)),
                    backgroundColor: Palette.ash,
                    side: BorderSide.none,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
