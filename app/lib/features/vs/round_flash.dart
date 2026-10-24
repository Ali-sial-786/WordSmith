import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/sfx.dart';
import '../../game/providers.dart';
import '../../game/vs_session.dart';
import '../../net/room_client.dart';
import '../../ui/effects/sparks.dart';
import '../../ui/mold/hammer_strike.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_frame.dart';
import '../../ui/widgets/game_icon.dart';
import 'team_widgets.dart';
import 'vs_widgets.dart';

/// What a finished Versus round's card says, from my side of the anvil: who
/// won it and how, and on the round that decided it, who won the series.
class RoundResult {
  const RoundResult(this.session, this.end);

  final VsSession session;
  final VsRoundEnd end;

  String? get winner => end.winner;

  /// Team Versus: rounds are won by a team.
  bool get team => end.isTeam;

  /// Someone won it: a racer, or in Team Versus a team.
  bool get hasWinner => team ? end.team != null : winner != null;

  /// I won it (Team Versus: my team did): the hot plaque, the hammer and the sparks.
  bool get won => team ? end.team != null && end.team == session.myTeam : winner != null && winner == session.me;

  /// The round that decided the series.
  bool get deciding => end.next == null;

  /// Sudden death: the round's own flag while this phone has that round, and
  /// otherwise past the regular rounds, where only sudden death is played.
  bool get suddenDeath {
    final r = session.round;
    if (r != null && (end.round == null || r.round == end.round)) return r.suddenDeath;
    return end.round != null && end.round! > session.series;
  }

  String get overline {
    if (suddenDeath) return 'Sudden death';
    final n = end.round ?? session.round?.round;
    return n == null ? 'Round over' : 'Round $n';
  }

  /// How it was won, or why nobody did.
  String get how {
    if (team) return _teamHow;
    final mine = {for (final p in end.progress) p.id: p}[winner];
    final letters = mine == null ? '' : ' (${mine.filled}/${mine.total})';
    final melted = end.melted;
    final whose = melted == null ? null : (melted.id == session.me ? 'Your' : "${session.nameOf(melted.id)}'s");
    return switch (end.how) {
      'finished' => 'Filled the whole mold first',
      'timeout' => 'Most letters when time ran out$letters',
      'survived' when whose != null => '$whose heated word melted · survived with the most letters$letters',
      'survived' => 'Survived the heat with the most letters$letters',
      _ when whose != null => '$whose heated word melted before anyone filled a letter',
      _ => 'Nobody filled a letter',
    };
  }

  /// Team Versus: how the round was won, by the rule.
  String get _teamHow {
    final scores = end.teamScores ?? const [0, 0];
    final t = end.team;
    if (t == null) return 'Nobody filled a letter';
    if (winner != null) {
      final name = winner == session.me ? 'You' : session.nameOf(winner!);
      return end.how == 'finished'
          ? '$name filled the whole mold first'
          : '$name had the most letters when time ran out';
    }
    return end.how == 'finished'
        ? 'Every mold on the team filled first'
        : 'Most letters added up: ${scores[t]} to ${scores[1 - t]}';
  }

  /// "You won the round", for the banner once the series' result has taken
  /// the headline.
  String get roundLine => team
      ? switch (end.team) {
          null => 'No winner this round',
          final t when t == session.myTeam => 'Your team won the round',
          final t => '${teamName(t)} won the round',
        }
      : switch (winner) {
          null => 'No winner this round',
          final id when id == session.me => 'You won the round',
          final id => '${session.nameOf(id)} won the round',
        };

  /// The series is over and its result is in (SERIES_END): the round that
  /// decided it only.
  bool get seriesKnown => deciding && session.seriesEnd != null;
  String? get seriesWinner => session.seriesEnd?.winner;
  bool get wonSeries {
    if (!seriesKnown) return false;
    if (team) return session.seriesEnd?.team != null && session.seriesEnd?.team == session.myTeam;
    return seriesWinner != null && seriesWinner == session.me;
  }

  /// "YOU WON THE ROUND!", or the winner's name in their colour.
  InlineSpan roundTitle(TextStyle style) => team
      ? _teamTitle(
          end.team,
          style,
          mine: 'YOUR TEAM WON THE ROUND!',
          theirs: ' won the round',
          none: 'No winner this round',
        )
      : _title(winner, style, mine: 'YOU WON THE ROUND!', theirs: ' won the round', none: 'No winner this round');

  InlineSpan seriesTitle(TextStyle style) => team
      ? _teamTitle(
          session.seriesEnd?.team,
          style,
          mine: 'YOUR TEAM WINS THE SERIES!',
          theirs: ' wins the series',
          none: 'Series over',
        )
      : _title(
          seriesWinner,
          style,
          mine: 'YOU WIN THE SERIES!',
          theirs: ' wins the series',
          // On the total score, only a tie on letters and bonus words has no winner.
          none: session.seriesEnd?.totalScore ?? false ? "It's a draw!" : 'Series over',
        );

  /// Team Versus: my team's line, or the team's name in its colour.
  InlineSpan _teamTitle(int? t, TextStyle style, {required String mine, required String theirs, required String none}) {
    if (t == null) return TextSpan(text: none, style: style);
    if (t == session.myTeam) return TextSpan(text: mine, style: style);
    return TextSpan(
      style: style,
      children: [
        TextSpan(
          text: teamName(t),
          style: TextStyle(color: Palette.team(t)),
        ),
        TextSpan(text: theirs),
      ],
    );
  }

  InlineSpan _title(String? id, TextStyle style, {required String mine, required String theirs, required String none}) {
    if (id == null) return TextSpan(text: none, style: style);
    if (id == session.me) return TextSpan(text: mine, style: style);
    return TextSpan(
      style: style,
      children: [
        TextSpan(
          text: session.nameOf(id),
          style: TextStyle(color: session.colorOf(id)),
        ),
        TextSpan(text: theirs),
      ],
    );
  }
}

/// The card that comes in when a Versus round ends: who won and how, the
/// series so far and, on the round that decided it, who won the series. My
/// own win is struck hot: a hammer comes down on a glowing gold plaque, with
/// sparks and embers. Anyone else's lands quietly on cold iron. After a few
/// seconds (sooner on a tap) it shrinks into [banner]'s place at the top of
/// the standings. With reduced motion it simply shows, then gives way.
class RoundFlash extends ConsumerStatefulWidget {
  const RoundFlash({
    super.key,
    required this.session,
    required this.end,
    required this.banner,
    this.onSettle,
    this.onSettled,
  });

  final VsSession session;
  final VsRoundEnd end;

  /// The [RoundBanner] it settles into, laid out (hidden) in the standings.
  final GlobalKey banner;

  /// When it starts to settle, and once it has (the banner takes over).
  final VoidCallback? onSettle;
  final VoidCallback? onSettled;

  @override
  ConsumerState<RoundFlash> createState() => _RoundFlashState();
}

class _RoundFlashState extends ConsumerState<RoundFlash> with SingleTickerProviderStateMixin {
  // The card's timeline, in ms from when it shows. A win lands with the
  // hammer; anyone else's drops in by then.
  static const _land = 380;

  /// The series' result comes in this long after, on the round that decided it.
  static const _seriesFrom = 1300;
  static const _seriesIn = 220;

  /// Up and readable this long, then it settles.
  static const _hold = 3800;

  /// The series' result stays up this long after it comes in.
  static const _seriesHold = 2400;

  /// How long to wait for SERIES_END before settling without it.
  static const _seriesWait = 6500;
  static const _settle = 450;

  static const _medal = 64.0;
  static const _cardPadding = EdgeInsets.fromLTRB(20, _medal / 2 + 10, 20, 20);

  late final Ticker _ticker = createTicker(_tick);
  late final bool _calm = ref.read(settingsProvider).reducedMotion;
  final _sparks = GlobalKey<SparkFieldState>();
  final _card = GlobalKey();
  final _ribbon = GlobalKey();
  final _chip = GlobalKey();

  /// Time since the card showed, and since it began to settle.
  double _ms = 0;
  double? _settleFrom;

  /// When the series' result came in.
  double? _seriesAt;

  /// The plaque where it showed, and the banner it settles into.
  Rect? _cardRect;
  Rect? _bannerRect;

  bool _started = false;
  bool _landed = false;
  bool _popped = false;
  bool _seriesLanded = false;

  RoundResult get _r => RoundResult(widget.session, widget.end);

  @override
  void initState() {
    super.initState();
    // Laid out first, so the hammer knows where to strike.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _cardRect = _rectOf(_card);
        _started = true;
      });
      _ticker.start();
      if (!_calm && _r.won) ref.read(sfxProvider).hammerStrike(const Duration(milliseconds: _land));
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    _ms = elapsed.inMicroseconds / 1000;
    final r = _r;
    if (!_landed && _ms >= _land) {
      _landed = true;
      _onLand(r);
    }
    if (!_popped && _ms >= _land + 500) {
      _popped = true;
      if (!_calm && r.won && r.hasWinner) _burstAt(_rectOf(_chip)?.center, count: 10, speed: 170);
    }
    if (r.deciding && _seriesAt == null && r.seriesKnown) _seriesAt = max(_ms, _seriesFrom.toDouble());
    if (!_seriesLanded && _seriesAt != null && _ms >= _seriesAt! + _seriesIn) {
      _seriesLanded = true;
      _onSeries(r);
    }
    final settleFrom = _settleFrom;
    if (settleFrom == null) {
      final due = !r.deciding
          ? _hold
          : _seriesAt == null
          ? _seriesWait
          : max(_hold, _seriesAt! + _seriesHold);
      if (_ms >= due) _beginSettle();
    } else if (_ms >= settleFrom + _settle) {
      _done();
      return;
    }
    if (mounted) setState(() {});
  }

  /// The hammer lands on my win: a clang, a jolt and a shower of sparks. Any
  /// other result just settles onto the anvil.
  void _onLand(RoundResult r) {
    if (_calm) return;
    final sfx = ref.read(sfxProvider);
    if (!r.won) {
      sfx.play(SfxId.clangLight, volume: 0.5);
      return;
    }
    if (ref.read(settingsProvider).haptics) HapticFeedback.heavyImpact();
    final card = _cardRect;
    if (card == null) return;
    _burstAt(_medalRect(card).center, count: 36, speed: 430, spread: pi * 2, size: 2.6);
    _burstAt(card.bottomLeft.translate(16, -8), count: 14, speed: 320, angle: -pi * 0.82, spread: 1.0);
    _burstAt(card.bottomRight.translate(-16, -8), count: 14, speed: 320, angle: -pi * 0.18, spread: 1.0);
  }

  void _onSeries(RoundResult r) {
    if (_calm) return;
    final sfx = ref.read(sfxProvider);
    if (!r.wonSeries) {
      sfx.play(SfxId.clangLight, volume: 0.5);
      return;
    }
    sfx.play(SfxId.clang);
    if (ref.read(settingsProvider).haptics) HapticFeedback.heavyImpact();
    final ribbon = _rectOf(_ribbon);
    if (ribbon == null) return;
    final colors = [Palette.gold, Palette.molten, Palette.whiteHeat];
    _burstAt(ribbon.center, count: 30, speed: 440, spread: pi * 2, colors: colors);
    // And off both ends of the plate.
    _burstAt(ribbon.centerLeft, count: 14, speed: 340, angle: pi * 1.15, spread: 1.2, colors: colors);
    _burstAt(ribbon.centerRight, count: 14, speed: 340, angle: -pi * 0.15, spread: 1.2, colors: colors);
  }

  void _burstAt(
    Offset? at, {
    int count = 18,
    double speed = 260,
    double angle = -pi / 2,
    double spread = pi * 1.6,
    double size = 2.2,
    List<Color>? colors,
  }) {
    final box = context.findRenderObject() as RenderBox?;
    if (at == null || box == null || !box.attached) return;
    _sparks.currentState?.burst(
      box.localToGlobal(at),
      count: count,
      speed: speed,
      angle: angle,
      spread: spread,
      size: size,
      colors: colors,
    );
  }

  /// A tap, or time's up: off to the banner.
  void _beginSettle() {
    if (_settleFrom != null || !_started) return;
    _settleFrom = _ms;
    widget.onSettle?.call();
    _cardRect = _rectOf(_card) ?? _cardRect;
    _bannerRect = _rectOf(widget.banner);
    // Nothing to fly to, or no flying: the banner just takes over.
    if (_calm || _cardRect == null || _bannerRect == null) _done();
  }

  void _done() {
    _ticker.stop();
    widget.onSettled?.call();
  }

  /// Where [key]'s box is laid out within this one (before any transform of its own).
  Rect? _rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    final mine = context.findRenderObject() as RenderBox?;
    if (box == null || mine == null || !box.attached || !box.hasSize || !mine.hasSize) return null;
    return mine.globalToLocal(box.localToGlobal(Offset.zero)) & box.size;
  }

  /// The medallion sits on the plaque's top edge.
  static Rect _medalRect(Rect card) => Rect.fromCenter(center: card.topCenter, width: _medal, height: _medal);

  /// 0 → 1 between [from] and [from] + [length] ms.
  double _phase(num from, num length) => _calm ? 1.0 : ((_ms - from) / length).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final settleFrom = _settleFrom;
    final t = settleFrom == null
        ? 0.0
        : Curves.easeInOutCubic.transform(((_ms - settleFrom) / _settle).clamp(0.0, 1.0));
    final shown = _calm ? 1.0 : (_started ? _phase(0, 200) : 0.0);
    // The plaque glows from the strike and cools; the series' strike heats it again.
    final heat = !r.won || _calm
        ? 0.0
        : max(
            _ms < _land ? 0.0 : 1 - _phase(_land, 1500),
            _seriesAt == null || !r.wonSeries ? 0.0 : 0.7 * (1 - _phase(_seriesAt! + _seriesIn, 1200)),
          );
    final card = _cardRect;
    final embers = r.won && !_calm && card != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(_beginSettle),
      child: SparkField(
        key: _sparks,
        child: Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: Opacity(
                opacity: shown * (1 - t),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Palette.forgeBlack.withValues(alpha: 0.82),
                    // The forge's glow behind a win.
                    gradient: r.won
                        ? RadialGradient(
                            center: const Alignment(0, -0.3),
                            radius: 0.75,
                            colors: [
                              Color.lerp(Palette.forgeBlack, Palette.ember, 0.35)!.withValues(alpha: 0.7),
                              Palette.forgeBlack.withValues(alpha: 0.85),
                            ],
                          )
                        : null,
                  ),
                ),
              ),
            ),
            if (embers)
              Positioned.fromRect(
                rect: Rect.fromLTRB(card.left - 30, card.top - 130, card.right + 30, card.bottom),
                child: Opacity(opacity: _phase(_land, 500) * (1 - t), child: const EmberDrift(count: 16)),
              ),
            if (settleFrom == null) _shown(r, heat) else ..._settling(r, t, heat),
            // The hammer comes down on the medallion.
            if (r.won && !_calm && card != null && _started && _ms < 1000)
              Positioned.fill(child: HammerStrike(cell: _medalRect(card))),
          ],
        ),
      ),
    );
  }

  /// The card, centred, as it comes in and while it's up.
  Widget _shown(RoundResult r, double heat) {
    var scale = 1.0;
    var offset = Offset.zero;
    var opacity = _started ? 1.0 : 0.0;
    if (!_calm && r.won) {
      // Drops onto the anvil as the hammer comes down, with a jolt where they meet.
      final fall = Curves.easeInCubic.transform(_phase(0, _land));
      offset = Offset(0, -150 * (1 - fall));
      scale = 1.12 - 0.12 * fall;
      opacity *= _phase(0, 120);
      final k = _phase(_land, 340);
      if (k > 0 && k < 1) {
        offset = Offset(sin(k * pi * 5) * 8 * (1 - k), cos(k * pi * 4) * 4 * (1 - k));
        scale -= 0.03 * sin(k * pi) * (1 - k);
      }
    } else if (!_calm) {
      // Settles down quietly.
      final k = Curves.easeOutCubic.transform(_phase(0, _land));
      offset = Offset(0, -28 * (1 - k));
      opacity *= k;
    }
    return LayoutBuilder(
      builder: (context, c) => Align(
        alignment: const Alignment(0, -0.3),
        child: Padding(
          padding: const EdgeInsets.only(top: _medal / 2),
          child: SizedBox(
            width: min(c.maxWidth - 40, 360),
            child: KeyedSubtree(
              key: _card,
              child: Transform.translate(
                offset: offset,
                child: Transform.scale(
                  scale: scale,
                  child: Opacity(
                    opacity: opacity.clamp(0.0, 1.0),
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.topCenter,
                      children: [
                        _Plaque(hot: r.won, heat: heat, padding: _cardPadding, child: _face(r)),
                        Positioned(
                          top: -_medal / 2,
                          child: _Medallion(r: r, size: _medal, heat: heat),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The card's words, each coming in on its beat.
  Widget _face(RoundResult r) => _CardFace(
    r: r,
    stamp: r.won ? _phase(_land, 180) : 1,
    cool: r.won ? _phase(_land, 900) : 1,
    details: r.won ? _phase(_land + 120, 300) : _phase(160, 300),
    pop: _phase(_land + 500, 320),
    series: _seriesAt == null ? null : _phase(_seriesAt!, r.wonSeries ? _seriesIn : 360),
    chipKey: _chip,
    ribbonKey: _ribbon,
  );

  /// The plaque shrinking from the card into the banner, the card's words
  /// giving way to the banner's.
  List<Widget> _settling(RoundResult r, double t, double heat) {
    final from = _cardRect!;
    final to = _bannerRect!;
    final rect = Rect.lerp(from, to, t)!;
    final medal = _medal * (1 - t * 0.5);
    return [
      Positioned.fromRect(
        rect: rect,
        child: _Plaque(
          hot: r.won,
          heat: heat * (1 - t),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Opacity(
                opacity: (1 - t * 2).clamp(0.0, 1.0),
                child: FittedBox(
                  child: SizedBox.fromSize(
                    size: from.size,
                    child: Padding(padding: _cardPadding, child: _face(r)),
                  ),
                ),
              ),
              Opacity(
                opacity: ((t - 0.35) / 0.65).clamp(0.0, 1.0),
                child: FittedBox(
                  child: SizedBox.fromSize(
                    size: to.size,
                    child: Padding(
                      padding: RoundBanner.padding,
                      child: _BannerFace(r: r),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      Positioned(
        left: rect.center.dx - medal / 2,
        top: rect.top - medal / 2,
        child: Opacity(
          opacity: (1 - t * 2.5).clamp(0.0, 1.0),
          child: _Medallion(r: r, size: medal, heat: heat),
        ),
      ),
    ];
  }
}

/// The round's result once its card has settled, at the top of the standings.
class RoundBanner extends StatelessWidget {
  const RoundBanner({super.key, required this.session, required this.end});

  final VsSession session;
  final VsRoundEnd end;

  static const padding = EdgeInsets.fromLTRB(12, 10, 14, 10);

  @override
  Widget build(BuildContext context) {
    final r = RoundResult(session, end);
    return _Plaque(
      hot: r.won,
      padding: padding,
      child: _BannerFace(r: r),
    );
  }
}

/// The plaque itself: gold and glowing for my win, struck hot ([heat] 1) and
/// cooling (0); otherwise iron with a cold, quenched cast.
class _Plaque extends StatelessWidget {
  const _Plaque({required this.hot, required this.child, this.heat = 0, this.padding = EdgeInsets.zero});

  final bool hot;
  final double heat;
  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(18),
      boxShadow: [
        BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 14, offset: const Offset(0, 5)),
        if (hot)
          BoxShadow(
            color: Palette.ember.withValues(alpha: 0.25 + 0.3 * heat),
            blurRadius: 16 + 26 * heat,
            spreadRadius: 2 * heat,
          ),
      ],
    ),
    child: Stack(
      fit: StackFit.passthrough,
      children: [
        // Solid metal behind the frame, so nothing shows through the words.
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: hot
                      ? const [Color(0xFF34281E), Color(0xFF1C1612)]
                      : const [Color(0xFF26292C), Color(0xFF151719)],
                ),
              ),
            ),
          ),
        ),
        ForgeFrame(
          kind: hot ? ForgeFrameKind.panelGold : ForgeFrameKind.panel,
          shadow: false,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: hot
                            ? RadialGradient(
                                center: const Alignment(0, -1),
                                radius: 1.1,
                                colors: [
                                  Palette.whiteHeat.withValues(alpha: 0.45 * heat),
                                  Palette.molten.withValues(alpha: 0.05 + 0.28 * heat),
                                  Palette.ember.withValues(alpha: 0),
                                ],
                                stops: const [0, 0.35, 1],
                              )
                            : const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0x2E7896B4), Color(0x0A304050)],
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(padding: padding, child: child),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The round boss on the plaque: a crown for the winner (gold if it's me,
/// steel if not), or the anvil when nobody won.
class _Medallion extends StatelessWidget {
  const _Medallion({required this.r, required this.size, this.heat = 0});

  final RoundResult r;
  final double size;
  final double heat;

  @override
  Widget build(BuildContext context) {
    final hot = r.won;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.3, -0.4),
          colors: hot
              ? [Color.lerp(const Color(0xFFFFE2A8), Palette.whiteHeat, heat)!, Palette.gold, const Color(0xFF8A5A1C)]
              : const [Color(0xFF7D848C), Color(0xFF4A4F55), Color(0xFF26292D)],
        ),
        border: Border.all(color: hot ? const Color(0xFFFFF1C4) : const Color(0xFF9AA3AC), width: size / 28),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: size / 8, offset: Offset(0, size / 20)),
          if (hot)
            BoxShadow(
              color: Palette.ember.withValues(alpha: 0.35 + 0.5 * heat),
              blurRadius: size * (0.2 + heat * 0.4),
            ),
        ],
      ),
      child: Center(
        child: GameIcon(
          r.hasWinner ? 'crown' : 'anvil',
          size: size * 0.52,
          color: hot ? Palette.darkLetter : Palette.whiteHeat,
        ),
      ),
    );
  }
}

/// The card's words: the round, who won it and how, the series so far and,
/// on the round that decided it, the series' result. Each part comes in on
/// its beat (0 → 1).
class _CardFace extends StatelessWidget {
  const _CardFace({
    required this.r,
    required this.stamp,
    required this.cool,
    required this.details,
    required this.pop,
    required this.series,
    required this.chipKey,
    required this.ribbonKey,
  });

  final RoundResult r;

  /// The headline stamped in by the hammer, and its cooling from white heat.
  final double stamp;
  final double cool;

  /// How it was won and the series so far.
  final double details;

  /// The winner's new flame.
  final double pop;

  /// The series' result, once it's in.
  final double? series;

  final GlobalKey chipKey;
  final GlobalKey ribbonKey;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final won = r.won;
    final titleColor = won
        ? Color.lerp(Palette.whiteHeat, Palette.molten, cool)!
        : Color.lerp(Palette.steel, Palette.whiteHeat, 0.55)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          r.overline.toUpperCase(),
          style: text.labelMedium?.copyWith(
            letterSpacing: 3,
            color: r.suddenDeath ? Palette.quenchRed : (won ? Palette.molten : Palette.steel),
          ),
        ),
        const SizedBox(height: 6),
        Opacity(
          opacity: (stamp * 4).clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 1.25 - 0.25 * Curves.easeOutCubic.transform(stamp),
            child: Text.rich(
              r.roundTitle(
                displayStyle(won ? 30 : 26, color: titleColor).copyWith(
                  height: 1.15,
                  shadows: won ? [Shadow(color: Palette.ember, blurRadius: 26 - 12 * cool)] : null,
                ),
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        Opacity(
          opacity: details,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - details)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Text(
                  r.how,
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: won ? Palette.whiteHeat.withValues(alpha: 0.9) : Palette.steel,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  height: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Palette.ash.withValues(alpha: 0),
                        won ? Palette.gold.withValues(alpha: 0.6) : Palette.iron,
                        Palette.ash.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  r.end.totalScore
                      ? 'TOTAL SCORE · ${r.session.series} ROUNDS'
                      : 'SERIES · BEST OF ${r.session.series}',
                  style: text.labelSmall?.copyWith(letterSpacing: 2),
                ),
                const SizedBox(height: 8),
                _Score(r: r, pop: pop, chipKey: chipKey),
              ],
            ),
          ),
        ),
        if (r.deciding) ...[
          const SizedBox(height: 16),
          SizedBox(
            height: 50,
            child: series == null ? null : _SeriesRibbon(key: ribbonKey, r: r, t: series!),
          ),
        ],
      ],
    );
  }
}

/// Everyone's round wins, as flames (a total score series: their scores);
/// the winner's newest flares as it lands.
class _Score extends StatelessWidget {
  const _Score({required this.r, required this.pop, required this.chipKey});

  final RoundResult r;
  final double pop;
  final GlobalKey chipKey;

  /// Team Versus: the two teams' round wins; the winning team's newest flares.
  Widget _teamScore(BuildContext context) {
    final s = r.session;
    final text = Theme.of(context).textTheme;
    final tally = r.end.teamTally ?? s.teamTally;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final team in const [0, 1]) ...[
          if (team == 1) const SizedBox(width: 18),
          Builder(
            builder: (context) {
              final flare = team == r.end.team ? sin(pop * pi) : 0.0;
              return Transform.scale(
                key: team == r.end.team ? chipKey : null,
                scale: 1 + 0.3 * flare,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      team == s.myTeam ? '${teamName(team)} (you)' : teamName(team),
                      style: text.labelMedium?.copyWith(color: Palette.team(team)),
                    ),
                    const SizedBox(height: 3),
                    SizedBox(
                      height: 16,
                      child: tally[team] == 0
                          ? Text('–', style: text.labelMedium?.copyWith(color: Palette.iron, height: 1))
                          : WinPips(wins: tally[team], color: Palette.team(team), size: 15),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = r.session;
    final text = Theme.of(context).textTheme;
    if (r.team) return _teamScore(context);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 8,
      children: [
        for (final id in s.standingsOrder)
          Builder(
            builder: (context) {
              final wins = r.end.tally[id] ?? 0;
              final score = r.end.scores?[id];
              final flare = id == r.winner ? sin(pop * pi) : 0.0;
              return Transform.scale(
                key: id == r.winner ? chipKey : null,
                scale: 1 + 0.3 * flare,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      if (flare > 0) BoxShadow(color: Palette.ember.withValues(alpha: 0.5 * flare), blurRadius: 16),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 76),
                        child: Text(
                          id == s.me ? 'You' : s.nameOf(id),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelMedium?.copyWith(color: id == s.me ? Palette.whiteHeat : Palette.steel),
                        ),
                      ),
                      const SizedBox(height: 3),
                      SizedBox(
                        height: 16,
                        child: score != null
                            ? Text('$score', style: text.labelLarge?.copyWith(color: s.colorOf(id), height: 1))
                            : wins == 0
                            ? Text('–', style: text.labelMedium?.copyWith(color: Palette.iron, height: 1))
                            : WinPips(wins: wins, color: s.colorOf(id), size: 15),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// "YOU WIN THE SERIES!" on a hot plate, slammed home; anyone else's on
/// plain iron, set down. [t] runs 0 → 1 as it comes in.
class _SeriesRibbon extends StatelessWidget {
  const _SeriesRibbon({super.key, required this.r, required this.t});

  final RoundResult r;
  final double t;

  @override
  Widget build(BuildContext context) {
    final mine = r.wonSeries;
    final scale = mine ? 1.5 - 0.5 * Curves.easeInCubic.transform(t) : 1.0;
    final drop = mine ? 0.0 : -14 * (1 - Curves.easeOutCubic.transform(t));
    return Opacity(
      opacity: mine ? (t * 3).clamp(0.0, 1.0) : t,
      child: Transform.translate(
        offset: Offset(0, drop),
        child: Transform.scale(
          scale: scale,
          child: ForgeFrame(
            kind: mine ? ForgeFrameKind.platePrimary : ForgeFrameKind.plate,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GameIcon('trophy', size: 22, color: mine ? Palette.darkLetter : Palette.steel),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text.rich(
                      r.seriesTitle(displayStyle(mine ? 18 : 16, color: mine ? Palette.darkLetter : Palette.whiteHeat)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The banner's words: the medallion, then the round (or once it's in, the
/// series' result) and how it went.
class _BannerFace extends StatelessWidget {
  const _BannerFace({required this.r});

  final RoundResult r;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final won = r.won;
    final series = r.seriesKnown;
    final hot = series ? r.wonSeries : won;
    final style = displayStyle(
      hot ? 17 : 16,
      color: hot ? Palette.molten : Color.lerp(Palette.steel, Palette.whiteHeat, 0.55),
    ).copyWith(height: 1.15, shadows: hot ? [Shadow(color: Palette.ember, blurRadius: 14)] : null);
    return Row(
      children: [
        _Medallion(r: r, size: 42),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                r.overline.toUpperCase(),
                style: text.labelSmall?.copyWith(
                  letterSpacing: 2,
                  color: r.suddenDeath ? Palette.quenchRed : (won ? Palette.molten : Palette.steel),
                ),
              ),
              Text.rich(series ? r.seriesTitle(style) : r.roundTitle(style), maxLines: 2),
              const SizedBox(height: 2),
              Text(
                series ? '${r.roundLine}. ${r.how}' : r.how,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: won ? Palette.whiteHeat.withValues(alpha: 0.85) : Palette.steel),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
