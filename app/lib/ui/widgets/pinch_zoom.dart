import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Pinching with two fingers zooms the whole game, anywhere, up to [maxScale]
/// (the phone's own text size doesn't reach the game, so this is the way to
/// see it bigger). Moving both fingers pans the zoomed view, and pinching
/// back out to about 1× snaps it home. One finger plays as usual, on the
/// zoomed view.
///
/// It follows touches with a [Listener], which sees them whatever the game
/// does with them, and only steps into the game's gestures once a second
/// finger lands: then it claims both touches, so a pinch that starts on the
/// anvil doesn't also forge a word.
class PinchZoom extends StatefulWidget {
  const PinchZoom({super.key, required this.child, this.maxScale = 3});

  final Widget child;
  final double maxScale;

  @override
  State<PinchZoom> createState() => _PinchZoomState();
}

class _PinchZoomState extends State<PinchZoom> {
  final _touches = <int, Offset>{};

  double _scale = 1;
  Offset _offset = Offset.zero;

  // Where the current pinch started.
  double _startSpread = 0;
  Offset _startFocus = Offset.zero;
  double _startScale = 1;
  Offset _startOffset = Offset.zero;

  // The two touches doing the pinch.
  (int, int)? _pinch;

  static bool _isTouch(PointerEvent e) => e.kind == PointerDeviceKind.touch || e.kind == PointerDeviceKind.stylus;

  void _down(PointerDownEvent e) {
    if (!_isTouch(e)) return;
    _touches[e.pointer] = e.localPosition;
    if (_pinch == null && _touches.length == 2) _begin();
  }

  void _move(PointerMoveEvent e) {
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.localPosition;
    if (_pinch != null) _update();
  }

  void _lift(PointerEvent e) {
    _touches.remove(e.pointer);
    final pinch = _pinch;
    if (pinch != null && (e.pointer == pinch.$1 || e.pointer == pinch.$2)) _end();
  }

  void _begin() {
    final [a, b] = _touches.keys.toList();
    _pinch = (a, b);
    _startSpread = (_touches[a]! - _touches[b]!).distance;
    _startFocus = (_touches[a]! + _touches[b]!) / 2;
    _startScale = _scale;
    _startOffset = _offset;
  }

  void _update() {
    final (a, b) = _pinch!;
    final pa = _touches[a], pb = _touches[b];
    final box = context.findRenderObject() as RenderBox?;
    if (pa == null || pb == null || box == null || _startSpread < 1) return;
    final spread = (pa - pb).distance;
    final focus = (pa + pb) / 2;
    final scale = (_startScale * spread / _startSpread).clamp(1.0, widget.maxScale);
    // Keep the spot that was under the fingers under them.
    final spot = (_startFocus - _startOffset) / _startScale;
    setState(() {
      _scale = scale;
      _offset = _clamp(focus - spot * scale, box.size, scale);
    });
  }

  void _end() {
    _pinch = null;
    if (_scale < 1.08) {
      setState(() {
        _scale = 1;
        _offset = Offset.zero;
      });
    }
  }

  /// No gaps at the edges: the zoomed game always covers the screen.
  static Offset _clamp(Offset offset, Size size, double scale) =>
      Offset(offset.dx.clamp(size.width * (1 - scale), 0.0), offset.dy.clamp(size.height * (1 - scale), 0.0));

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: _lift,
    onPointerCancel: _lift,
    child: RawGestureDetector(
      gestures: {_PinchClaim: GestureRecognizerFactoryWithHandlers<_PinchClaim>(_PinchClaim.new, (_) {})},
      child: ClipRect(
        child: Transform(
          transform: Matrix4.identity()
            ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
            ..scaleByDouble(_scale, _scale, 1, 1),
          child: widget.child,
        ),
      ),
    ),
  );
}

/// Takes part in every touch's gesture arena without a say until a second
/// finger is down, then wins both, so the game's own gesture lets go. A touch
/// the game has already claimed stays the game's.
class _PinchClaim extends OneSequenceGestureRecognizer {
  _PinchClaim() : super(supportedDevices: {PointerDeviceKind.touch, PointerDeviceKind.stylus});

  final _down = <int>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    _down.add(event.pointer);
    if (_down.length >= 2) resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _down.remove(event.pointer);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    _down.remove(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'pinch zoom';
}
