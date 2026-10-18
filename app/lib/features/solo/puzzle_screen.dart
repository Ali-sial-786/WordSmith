import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../audio/sfx.dart';
import '../../engine/board.dart';
import '../../engine/hints.dart';
import '../../engine/masterworks.dart';
import '../../engine/pickups.dart';
import '../../engine/puzzle.dart';
import '../../game/account.dart';
import '../../game/daily_game.dart';
import '../../game/history_records.dart';
import '../../game/providers.dart';
import '../../game/replay_game.dart';
import '../../game/solo_controller.dart';
import '../../net/api_client.dart';
import '../../net/models.dart';
import '../../ui/anvil/anvil_ring.dart';
import '../../ui/effects/sparks.dart';
import '../../ui/mold/mold_grid.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/meaning_sheet.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/toast_line.dart';
import '../../ui/widgets/word_preview.dart';
import 'forged_overlay.dart';

class PuzzleScreen extends ConsumerStatefulWidget {
  const PuzzleScreen({super.key, required int this.stage, this.replay = false}) : daily = null;

  /// Today's Daily Commission instead of a campaign stage.
  const PuzzleScreen.daily({super.key, required DailyInfo this.daily}) : stage = null, replay = false;

  final int? stage;
  final DailyInfo? daily;

  /// A finished campaign puzzle played again from the chapter map.
  final bool replay;

  @override
  ConsumerState<PuzzleScreen> createState() => _PuzzleScreenState();
}

class _PuzzleScreenState extends ConsumerState<PuzzleScreen> with WidgetsBindingObserver {
  late final SoloGame _game;
  final _cues = MoldCues();
  final _preview = GlobalKey<WordPreviewState>();
  final _toast = GlobalKey<ToastLineState>();
  final _moldKey = GlobalKey();
  final _scrapKey = GlobalKey();
  String _word = '';
  bool _chisel = false;
  bool _finishing = false;

  /// Read once: delayed sound callbacks can fire after the screen is gone.
  late final Sfx _sfx;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sfx = ref.read(sfxProvider);
    final daily = widget.daily;
    final api = ref.read(apiClientProvider);
    // Outlives this screen, so a result that lands after leaving still
    // refreshes the Forge Hall.
    final container = ProviderScope.containerOf(context, listen: false);
    _game =
        (daily != null && api != null
              ? DailyGame(
                  info: daily,
                  api: api,
                  store: ref.read(storeProvider),
                  profile: ref.read(profileProvider.notifier),
                  onForged: () {
                    container
                      ..invalidate(dailyProvider)
                      ..invalidate(dailyForDateProvider(daily.date))
                      ..invalidate(dailyCalendarProvider);
                  },
                )
              : widget.replay
              ? ReplayGame(
                  stage: widget.stage!,
                  campaign: ref.read(campaignProvider),
                  profile: ref.read(profileProvider.notifier),
                )
              : SoloController(
                  stage: widget.stage!,
                  campaign: ref.read(campaignProvider),
                  store: ref.read(storeProvider),
                  profile: ref.read(profileProvider.notifier),
                ))
          ..addListener(_onGameChanged);
    if (_game.isComplete) _finish();
    _account = ref.read(accountProvider.notifier)..setStatus('solo');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) HammerStrike.precache(context);
      _startTips();
    });
  }

  /// Explains a gilded cell or an ember the first time a puzzle has one.
  void _startTips() {
    if (!mounted || _game.isComplete) return;
    final store = ref.read(storeProvider);
    final board = _game.board;
    final tips = [
      if (board.gilded != null && !board.gildedCollected)
        ('gilded', 'A gilded cell! Forge its word for a blueprint piece.', Palette.gold),
      if (board.pickups.isNotEmpty) ('ember', 'An ember! Forge its word for a free hint.', Palette.molten),
    ].where((t) => !store.seenTip(t.$1)).toList();
    for (final (i, (id, text, color)) in tips.indexed) {
      store.markTip(id);
      Future.delayed(Duration(milliseconds: 600 + 2600 * i), () {
        if (mounted) _toast.currentState?.show(text, color: color);
      });
    }
  }

  /// The tiles a first-time player is shown swiping: the puzzle's shortest
  /// word, until they forge their first one.
  List<int>? get _guide {
    if (widget.stage != 1 || widget.replay || _game.board.foundSlots.isNotEmpty || _finishing) return null;
    // A looping hand is too much motion for some; the text hint stays.
    if (ref.read(settingsProvider).reducedMotion) return null;
    final word = (_game.board.puzzle.slots.map((s) => s.word).toList()..sort((a, b) => a.length - b.length)).first;
    final used = <int>[];
    for (final ch in word.split('')) {
      final tile = List.generate(
        _game.letters.length,
        (i) => i,
      ).firstWhere((i) => _game.letters[i] == ch && !used.contains(i), orElse: () => -1);
      if (tile < 0) return null;
      used.add(tile);
    }
    return used;
  }

  late final AccountController _account;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _game.pause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _account.setStatus('online');
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
        _announcePickups(r.collected, gilded: r.gilded);
        final store = ref.read(storeProvider);
        if (!store.seenTip('meaning') && !r.gilded && r.collected.isEmpty && !_game.isComplete) {
          store.markTip('meaning');
          Future.delayed(const Duration(milliseconds: 900), () {
            if (mounted) _toast.currentState?.show('Tip: tap a forged word to see what it means');
          });
        }
      case SubmitOutcome.bonus:
        _preview.currentState?.react(r.word, PreviewResult.bonus);
        _sfx.play(SfxId.bonus);
        _haptic(HapticFeedback.lightImpact);
        _burstAt(_scrapKey, small: true);
        final bin = ref.read(profileProvider).scrapBin;
        if (widget.replay) {
          _toast.currentState?.show('Bonus word!', color: Palette.verdigris);
        } else if (fb.smelted) {
          Future.delayed(const Duration(milliseconds: 350), () {
            _sfx.play(SfxId.pickup);
            _burstAt(_scrapKey);
          });
          _toast.currentState?.show('Scrap Bin smelted: +1 Hammer Strike!', color: Palette.molten);
        } else {
          _toast.currentState?.show('Bonus word! Scrap Bin $bin/$scrapBinCapacity', color: Palette.verdigris);
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

  void _announcePickups(List<Pickup> pickups, {bool gilded = false}) {
    if (pickups.isNotEmpty) {
      Future.delayed(const Duration(milliseconds: 450), () {
        if (!mounted) return;
        _sfx.play(SfxId.pickup);
        final names = pickups.map((p) => '+1 ${p.kind.title}').join(', ');
        _toast.currentState?.show('Ember found! $names', color: Palette.molten);
      });
    }
    if (gilded) {
      Future.delayed(Duration(milliseconds: pickups.isEmpty ? 450 : 1500), () {
        if (!mounted) return;
        _sfx.play(SfxId.gilded);
        _burstAt(_moldKey, small: true);
        // The piece is already counted; show the Masterwork it went to.
        final before = MasterworkProgress(ref.read(profileProvider).masterworkPieces - 1);
        final spec = before.current;
        _toast.currentState?.show(
          spec == null
              ? 'Blueprint piece found!'
              : 'Blueprint piece found! ${before.piecesInCurrent + 1}/${spec.pieces}',
          color: Palette.gold,
        );
      });
    }
  }

  void _afterReveal(RevealResult? r, SfxId sound) {
    if (r == null) return;
    _sfx.play(sound);
    _haptic(HapticFeedback.mediumImpact);
    for (final s in r.completedSlots) {
      _cues.stagger(s.cells);
    }
    _announcePickups(r.collected, gilded: r.gilded);
    if (_game.isComplete) _finish();
  }

  void _useHint(HintKind kind) {
    if (_finishing) return;
    if (widget.replay) {
      _toast.currentState?.show('Replays are just for fun: no hints', color: Palette.steel);
      return;
    }
    final level = ref.read(profileProvider).level;
    if (!kind.unlockedAt(level)) {
      _toast.currentState?.show('${kind.title} unlocks at Smith Level ${kind.unlockLevel}');
      return;
    }
    if (!_game.canUse(kind)) {
      _toast.currentState?.show('No ${kind.title}s left: level up or find embers', color: Palette.steel);
      return;
    }
    switch (kind) {
      case HintKind.hammer:
        _strike(_game.useHammer());
      case HintKind.chisel:
        setState(() => _chisel = !_chisel);
        if (_chisel) _toast.currentState?.show('Tap a cell to chisel its letter');
      case HintKind.sparks:
        _afterReveal(_game.useSparks(), SfxId.hintSparks);
    }
  }

  /// The hammer swings down onto the revealed cell; its letter, and any
  /// word it completes, show as it lands.
  void _strike(RevealResult? r) {
    if (r == null) return;
    _cues.strike(r.cells.single, completed: [for (final s in r.completedSlots) s.cells]);
    _sfx.hammerStrike(hammerImpact);
    Future.delayed(hammerImpact, () => _haptic(HapticFeedback.heavyImpact));
    _announcePickups(r.collected, gilded: r.gilded);
    if (_game.isComplete) _finish();
  }

  void _onChiselCell(CellPos cell) {
    setState(() => _chisel = false);
    _afterReveal(_game.useChisel(cell), SfxId.hintChisel);
  }

  /// The forged words through [cell], with their meanings.
  void _showWordsAt(CellPos cell) {
    final board = _game.board;
    final words = [
      for (final s in board.puzzle.slotsAt[cell] ?? const <Slot>[])
        if (board.isSlotComplete(s)) s.word,
    ];
    showMeanings(context, words);
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
    final game = _game;
    // Into the history straight away, and again with its XP once known.
    final history = ref.read(historyProvider.notifier);
    final at = DateTime.now().millisecondsSinceEpoch;
    history.add(soloRecord(game, at: at));
    // Campaign results sync in the background; the daily one is sent now.
    if (game is SoloController) _account.sync();
    final rewardSoon = _reward().then((reward) {
      if (reward != null && game is! ReplayGame) history.add(soloRecord(game, at: at, xp: reward.xp));
      return reward;
    });
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    if (!mounted) return;
    _sfx.play(SfxId.forged);
    _haptic(HapticFeedback.heavyImpact);
    for (var i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: i * 140), () => _burstAt(_moldKey));
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final reward = await rewardSoon;
    if (!mounted) return;
    if (reward == null) {
      context.go('/');
      return;
    }
    if (reward.leveledUp) {
      Future.delayed(const Duration(milliseconds: 900), () => _sfx.play(SfxId.levelUp));
    }
    if (reward.masterwork != null) {
      Future.delayed(const Duration(milliseconds: 1700), () => _sfx.play(SfxId.masterwork));
    }
    final campaign = ref.read(campaignProvider);
    final next = (widget.stage ?? 0) + 1;

    if (game is ReplayGame) {
      await showForgedOverlay(
        context,
        reward: reward,
        chapter: game.chapter,
        nextChapter: null,
        replay: true,
        pickups: const [],
        bonusWords: game.board.bonusFound.length,
        words: [for (final s in game.board.puzzle.slots) s.word]
          ..sort((a, b) => b.length != a.length ? b.length - a.length : a.compareTo(b)),
      );
      if (mounted) context.canPop() ? context.pop() : context.go('/chapters');
      return;
    }
    final action = await showForgedOverlay(
      context,
      reward: reward,
      chapter: game is SoloController ? game.chapter : null,
      nextChapter: game is SoloController && next <= campaign.maxStage ? campaign.chapterFor(next) : null,
      daily: game is DailyGame ? game.outcome : null,
      dailyLate: game is DailyGame && game.info.date != todayUtc(),
      // A first completion of a commission unlocks the next Lore page.
      lorePage: game is DailyGame && game.outcome?.alreadyDone == false ? game.info.total : null,
      pickups: [for (final i in _game.board.collectedPickups) _game.board.pickups[i]],
      bonusWords: _game.board.bonusFound.length,
      words: [for (final s in _game.board.puzzle.slots) s.word]
        ..sort((a, b) => b.length != a.length ? b.length - a.length : a.compareTo(b)),
    );
    if (!mounted) return;
    if (game is SoloController && action == ForgedAction.next && next <= campaign.maxStage) {
      context.pushReplacement('/play/$next');
    } else {
      context.go('/');
    }
  }

  /// The reward, asking to retry if the daily result can't reach the server.
  /// Null if the player gives up.
  Future<CompletionReward?> _reward() async {
    while (true) {
      try {
        return await _game.finish();
      } on ApiException catch (e) {
        if (!mounted) return null;
        // Problems trying again can't fix (an old day's puzzle, say).
        if (!e.offline && e.status != 409 && e.status < 500) {
          ProviderScope.containerOf(context, listen: false).invalidate(dailyProvider);
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text("That commission can't be forged"),
              content: Text(e.friendly),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
            ),
          );
          return null;
        }
        final retry = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text("Couldn't reach the forge"),
            content: Text('${e.friendly}\n\nYour commission is done; try sending it again.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Later')),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Try again')),
            ],
          ),
        );
        if (retry != true) return null;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider);
    final reducedMotion = ref.watch(settingsProvider.select((s) => s.reducedMotion));
    final leftHanded = ref.watch(settingsProvider.select((s) => s.leftHanded));
    final metal = MetalStyle.forChapter(_game.look);
    return Scaffold(
      body: ForgeBackground(
        image: chapterBackground(_game.look),
        warmth: chapterWarmth(_game.look),
        fire: 1,
        fireHeight: 0.5,
        child: SparkField(
          intensity: reducedMotion ? 0.35 : 1,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, c) {
                final ring = min(c.maxWidth * 0.64, c.maxHeight * 0.37);
                final side = (c.maxWidth - ring) / 2;
                final tools = SizedBox(
                  width: side,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      KeyedSubtree(
                        key: _scrapKey,
                        child: _ScrapBin(count: profile.scrapBin, words: _game.board.bonusFound),
                      ),
                      RoundMetalButton(icon: 'turn', tooltip: 'Turn the tiles', onPressed: _finishing ? null : _turn),
                    ],
                  ),
                );
                final hints = SizedBox(
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
                );
                return Column(
                  children: [
                    _TopBar(title: _game.title, subtitle: _game.subtitle),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
                        child: KeyedSubtree(
                          key: _moldKey,
                          child: MoldGrid(
                            mold: BoardMold(_game.board),
                            metal: metal,
                            cues: _cues,
                            chiselMode: _chisel,
                            onCellTap: _onChiselCell,
                            onFilledTap: _showWordsAt,
                          ),
                        ),
                      ),
                    ),
                    ToastLine(key: _toast),
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        if ((widget.stage ?? 99) <= 2 && _game.board.foundSlots.isEmpty)
                          AnimatedOpacity(
                            opacity: _word.isEmpty ? 1 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: Text(
                              'Swipe across the letters to forge a word',
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Palette.molten),
                            ),
                          ),
                        WordPreview(key: _preview, word: _word),
                      ],
                    ),
                    SizedBox(
                      height: ring + 8,
                      child: Row(
                        children: [
                          if (leftHanded) hints else tools,
                          AnvilRing(
                            letters: _game.letters,
                            order: _game.order,
                            size: ring,
                            enabled: !_finishing && !_chisel,
                            guide: _guide,
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
      height: 60,
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
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: displayStyle(19)),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
            icon: GameIcon('settings', size: 24, color: Palette.steel),
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
            GameIcon('scrap_bucket', size: 28, color: Palette.steel),
            Positioned(
              bottom: 2,
              child: Text(
                '$count/$scrapBinCapacity',
                style: TextStyle(
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
          Text('Found in this puzzle (tap one to see what it means)', style: text.titleSmall),
          const SizedBox(height: 8),
          if (sorted.isEmpty)
            Text('None yet.', style: text.bodySmall)
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final w in sorted)
                  ActionChip(
                    label: Text(w, style: letterStyle(14)),
                    tooltip: 'What does $w mean?',
                    backgroundColor: Palette.ash,
                    side: BorderSide.none,
                    onPressed: () => showMeanings(context, [w]),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
