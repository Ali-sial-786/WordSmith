import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Sound in the browser with one shared Web Audio context, decoded buffers
/// for the effects (any number can overlap, with no lag) and looping
/// buffers for the music and ambience. The files are MP3 copies served
/// next to the web build (app/web/audio, tools/web_audio.sh): Safari on
/// older iPhones can't play Ogg Vorbis.
///
/// iOS only lets sound start from a tap, so the context is resumed, and a
/// silent buffer played, inside the first touch, click or key press.
class WebSound {
  WebSound() {
    _unlock = ((web.Event _) => _onGesture()).toJS;
    for (final type in _gestures) {
      web.document.addEventListener(type, _unlock, web.AddEventListenerOptions(capture: true));
    }
  }

  static bool get supported => true;

  static const _gestures = ['touchend', 'pointerup', 'click', 'keydown'];

  final web.AudioContext _ctx = web.AudioContext();
  late final JSFunction _unlock;
  bool _unlocked = false;
  final Map<String, web.AudioBuffer> _buffers = {};
  final Map<String, Future<web.AudioBuffer?>> _loading = {};

  /// Per loop channel (`music`, `ambience`): what plays, its gain and file.
  final Map<String, ({web.AudioBufferSourceNode source, web.GainNode gain, String file})> _loops = {};
  final Map<String, double> _loopVolumes = {};
  bool _quiet = false;

  void _onGesture() {
    if (_unlocked) return;
    // Must happen inside the gesture's own handler.
    _ctx.resume();
    final silent = _ctx.createBufferSource()..buffer = _ctx.createBuffer(1, 1, 22050);
    silent.connect(_ctx.destination);
    silent.start();
    if (_ctx.state == 'running' || !_isIOS) _finishUnlock();
    // iOS reports `running` a moment later.
    Timer(const Duration(milliseconds: 300), () {
      if (_ctx.state == 'running') _finishUnlock();
    });
  }

  void _finishUnlock() {
    if (_unlocked) return;
    _unlocked = true;
    for (final type in _gestures) {
      web.document.removeEventListener(type, _unlock, web.EventListenerOptions(capture: true));
    }
  }

  static bool get _isIOS {
    final ua = web.window.navigator.userAgent;
    return ua.contains('iPhone') ||
        ua.contains('iPad') ||
        (ua.contains('Macintosh') && web.window.navigator.maxTouchPoints > 1);
  }

  Future<web.AudioBuffer?> _buffer(String file) => _loading[file] ??= () async {
    try {
      final res = await web.window.fetch('audio/$file.mp3'.toJS).toDart;
      if (!res.ok) throw StateError('HTTP ${res.status}');
      final bytes = await res.arrayBuffer().toDart;
      final buffer = await _ctx.decodeAudioData(bytes).toDart;
      _buffers[file] = buffer;
      return buffer;
    } on Object catch (e) {
      debugPrint('sound $file unavailable: $e');
      return null;
    }
  }();

  /// Fetches and decodes [files] (the short effects) ahead of time.
  Future<void> load(Iterable<String> files) => Future.wait(files.map(_buffer));

  /// Plays an effect once. Silent until it has loaded.
  void play(String file, double volume) {
    final buffer = _buffers[file];
    if (buffer == null || _quiet || volume <= 0) return;
    if (_ctx.state != 'running') _ctx.resume();
    final gain = _ctx.createGain()..gain.value = volume;
    final source = _ctx.createBufferSource()..buffer = buffer;
    source.connect(gain);
    gain.connect(_ctx.destination);
    source.start();
  }

  /// Loops [file] on [channel] (replacing what played there), or stops the
  /// channel with null.
  Future<void> loop(String channel, String? file, double volume) async {
    _loopVolumes[channel] = volume;
    final old = _loops[channel];
    if (old != null && old.file == file) return;
    _loops.remove(channel);
    old?.source.stop();
    if (file == null) return;
    final buffer = await _buffer(file);
    // Something else was asked for meanwhile.
    if (buffer == null || _loops.containsKey(channel)) return;
    final gain = _ctx.createGain()..gain.value = _loopVolumes[channel] ?? volume;
    final source = _ctx.createBufferSource()
      ..buffer = buffer
      ..loop = true;
    // Skip the MP3 encoder's padding, so the loop has no gap.
    if (buffer.duration > 1) {
      source
        ..loopStart = 0.03
        ..loopEnd = buffer.duration - 0.03;
    }
    source.connect(gain);
    gain.connect(_ctx.destination);
    source.start();
    _loops[channel] = (source: source, gain: gain, file: file);
  }

  void setLoopVolume(String channel, double volume) {
    _loopVolumes[channel] = volume;
    _loops[channel]?.gain.gain.value = volume;
  }

  /// Everything goes quiet (the page is hidden) or comes back.
  Future<void> setQuiet(bool quiet) async {
    _quiet = quiet;
    try {
      quiet ? await _ctx.suspend().toDart : await _ctx.resume().toDart;
    } on Object catch (e) {
      debugPrint('audio ${quiet ? 'suspend' : 'resume'}: $e');
    }
  }

  Future<void> close() async {
    for (final l in _loops.values) {
      l.source.stop();
    }
    _loops.clear();
    await _ctx.close().toDart;
  }
}
