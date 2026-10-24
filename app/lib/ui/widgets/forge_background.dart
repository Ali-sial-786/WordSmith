import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/providers.dart';
import '../effects/forge_fire.dart';
import '../effects/sparks.dart';
import '../theme/palette.dart';

/// A dimmed scene image (blurred if asked) behind a screen, with an animated
/// forge fire along the bottom and drifting embers. Falls back to a warm
/// gradient while art is missing.
class ForgeBackground extends ConsumerWidget {
  const ForgeBackground({
    super.key,
    required this.image,
    required this.child,
    this.dim = 0.55,
    this.blur = 0,
    this.fire = 0.8,
    this.fireHeight = 0.42,
    this.warmth = 1,
  });

  /// Asset path, e.g. `assets/images/bg_tin.webp`.
  final String image;
  final Widget child;
  final double dim;
  final double blur;

  /// Strength (0–1) of the animated forge fire along the bottom; 0 hides it.
  final double fire;

  /// Fraction of the screen height the fire layer covers.
  final double fireHeight;

  /// How strongly to warm the picture (0 leaves it as rendered). Moonlit and
  /// cool chapters use less, so their blues survive.
  final double warmth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reducedMotion = ref.watch(settingsProvider.select((s) => s.reducedMotion));
    final light = Palette.isLight;
    // Dark text needs a pale scene: a light scheme washes the picture out
    // much more, and evenly from top to bottom.
    final wash = light ? [0.5 + 0.3 * dim, 0.55 + 0.3 * dim, 0.6 + 0.3 * dim] : [dim * 0.8, dim, dim * 1.25];
    // Warm grade: dimmed yellow firelight otherwise drifts olive. Other
    // schemes tint the picture their own colour instead.
    final grade = ColorFilter.matrix(
      SchemeFilters.scene() ??
          [
            1 + 0.06 * warmth, 0, 0, 0, 0, //
            0, 1 - 0.14 * warmth, 0, 0, 0, //
            0, 0, 1 - 0.3 * warmth, 0, 0, //
            0, 0, 0, 1, 0, //
          ],
    );
    final fireTint = SchemeFilters.fire();
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          enabled: blur > 0,
          imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: _Scene(
            image: image,
            grade: grade,
            wash: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [for (final a in wash) Palette.forgeBlack.withValues(alpha: a.clamp(0.0, 1.0))],
            ),
            fallback: RadialGradient(
              center: Alignment(0, 0.9),
              radius: 1.3,
              colors: [
                Palette.scheme.asRendered ? Color(0xFF4A2412) : Color.lerp(Palette.forgeBlack, Palette.ember, 0.25)!,
                Palette.soot,
                Palette.forgeBlack,
              ],
              stops: [0, 0.45, 1],
            ),
          ),
        ),
        if (fire > 0)
          Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: fireHeight,
              widthFactor: 1,
              // On a pale scene the coals would be a dark smudge: a lower glow.
              // Other schemes burn in their own accent (a gas forge's blue, say).
              child: ForgeFire(
                intensity: light ? fire * 0.5 : fire,
                animate: !reducedMotion,
                colorFilter: fireTint == null ? null : ColorFilter.matrix(fireTint),
              ),
            ),
          ),
        if (!reducedMotion) const EmberDrift(count: 22),
        child,
      ],
    );
  }
}

/// The scene picture, colour-graded, under the [wash] that dims it; the
/// [fallback] gradient until the picture has loaded (they're opaque and cover
/// the screen, so it isn't drawn underneath them).
///
/// The fire redraws the screen many times a second, so once the size has
/// settled the graded, washed picture is drawn once into an image of the
/// screen's pixels, and each frame just copies that.
class _Scene extends StatefulWidget {
  const _Scene({required this.image, required this.grade, required this.wash, required this.fallback});

  final String image;
  final ColorFilter grade;
  final Gradient wash;
  final Gradient fallback;

  @override
  State<_Scene> createState() => _SceneState();
}

typedef _Look = (ui.Image, Size, double, ColorFilter, Gradient);

class _SceneState extends State<_Scene> {
  /// How long the size must hold before it's worth an image: not on every
  /// frame of a keyboard sliding up, say.
  static const _settle = Duration(milliseconds: 300);

  ImageStream? _stream;
  ImageInfo? _info;
  late final _listener = ImageStreamListener((info, _) {
    if (!mounted) return info.dispose();
    setState(() {
      _info?.dispose();
      _info = info;
    });
  }, onError: (e, _) => debugPrint('scene ${widget.image}: $e'));

  ({_Look look, ui.Image image})? _baked;
  _Look? _waiting;
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_Scene oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _resolve();
  }

  void _resolve() {
    final stream = AssetImage(widget.image).resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  /// Draws [look] into an image once its size has held for [_settle].
  void _bakeLater(_Look look) {
    if (look == _waiting) return;
    _waiting = look;
    _timer?.cancel();
    _timer = Timer(_settle, () {
      if (!mounted || _waiting != look) return;
      final (picture, size, dpr, _, _) = look;
      final recorder = ui.PictureRecorder();
      _ScenePainter(picture, widget.grade, widget.wash).paint(Canvas(recorder)..scale(dpr), size);
      final drawn = recorder.endRecording();
      final image = drawn.toImageSync((size.width * dpr).ceil(), (size.height * dpr).ceil());
      drawn.dispose();
      setState(() {
        _baked?.image.dispose();
        _baked = (look: look, image: image);
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stream?.removeListener(_listener);
    _info?.dispose();
    _baked?.image.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null) {
      return DecoratedBox(
        decoration: BoxDecoration(gradient: widget.fallback),
        child: DecoratedBox(decoration: BoxDecoration(gradient: widget.wash)),
      );
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, c) {
        final look = (info.image, c.biggest, dpr, widget.grade, widget.wash);
        if (_baked case (look: final baked, :final image) when baked == look) {
          return CustomPaint(painter: _CopyPainter(image, dpr));
        }
        _bakeLater(look);
        return CustomPaint(painter: _ScenePainter(info.image, widget.grade, widget.wash));
      },
    );
  }
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.image, this.grade, this.wash);

  final ui.Image image;
  final ColorFilter grade;
  final Gradient wash;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // The grade is applied as the picture is drawn: a ColorFiltered would
    // need a layer the size of the screen.
    paintImage(
      canvas: canvas,
      rect: rect,
      image: image,
      fit: BoxFit.cover,
      colorFilter: grade,
      filterQuality: FilterQuality.low,
    );
    canvas.drawRect(rect, Paint()..shader = wash.createShader(rect));
  }

  @override
  bool shouldRepaint(_ScenePainter old) => old.image != image || old.grade != grade || old.wash != wash;
}

/// Copies an image drawn at [dpr], pixel for pixel.
class _CopyPainter extends CustomPainter {
  _CopyPainter(this.image, this.dpr);

  final ui.Image image;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    // The image is whole pixels, so it may reach a fraction past the box.
    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..scale(1 / dpr)
      ..drawImage(image, Offset.zero, Paint()..filterQuality = FilterQuality.low)
      ..restore();
  }

  @override
  bool shouldRepaint(_CopyPainter old) => old.image != image || old.dpr != dpr;
}
