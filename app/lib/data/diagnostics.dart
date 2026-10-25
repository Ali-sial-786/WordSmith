import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_info.dart';

/// What Android recorded about the game's last crash (Android 11+), kept by
/// MainActivity.kt.
class CrashReport {
  const CrashReport({
    required this.kind,
    required this.at,
    required this.description,
    required this.backend,
    required this.trace,
    this.pssKb = 0,
    this.rssKb = 0,
    this.updatedAt,
  });

  factory CrashReport.fromJson(Map<String, dynamic> json) => CrashReport(
    kind: json['kind'] as String? ?? 'crash',
    at: DateTime.fromMillisecondsSinceEpoch(json['at'] as int? ?? 0, isUtc: true),
    description: json['description'] as String? ?? '',
    backend: json['backend'] as String? ?? 'vulkan',
    trace: json['trace'] as String? ?? '',
    pssKb: json['pssKb'] as int? ?? 0,
    rssKb: json['rssKb'] as int? ?? 0,
    updatedAt: switch (json['updatedAt']) {
      final int t when t > 0 => DateTime.fromMillisecondsSinceEpoch(t, isUtc: true),
      _ => null,
    },
  );

  /// `native_crash`, `crash`, `anr`, `low_memory` or `init_failure`.
  final String kind;
  final DateTime at;
  final String description;

  /// The renderer it crashed with: `vulkan` or `opengles`.
  final String backend;
  final String trace;
  final int pssKb;
  final int rssKb;

  /// When the version now installed was installed; a crash before then was
  /// in the version before (say, while updating).
  final DateTime? updatedAt;

  String get title => switch (kind) {
    'native_crash' => 'Crashed (native code)',
    'anr' => 'Stopped responding',
    'low_memory' => 'Closed to free memory',
    'init_failure' => "Couldn't start",
    _ => 'Crashed',
  };

  /// A plain-text report to paste into a message.
  String toText({required String device, List<String> errors = const []}) {
    final b = StringBuffer()
      ..writeln('Wordsmith $appVersion crash report')
      ..writeln('Device: $device')
      ..writeln('When: ${at.toIso8601String()}')
      ..writeln(switch (updatedAt) {
        final u? when at.isBefore(u) => 'Installed: ${u.toIso8601String()} (the crash was in the version before)',
        final u? => 'Installed: ${u.toIso8601String()}',
        null => 'Installed: unknown',
      })
      ..writeln('What: $kind ($title), graphics: $backend')
      ..writeln('Memory: pss ${pssKb ~/ 1024} MB, rss ${rssKb ~/ 1024} MB');
    if (description.isNotEmpty) b.writeln('Description: $description');
    if (errors.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Recent app errors:');
      errors.forEach(b.writeln);
    }
    if (trace.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Trace:')
        ..write(trace);
    }
    return b.toString();
  }
}

/// The renderer setting. [compat] switches from Vulkan to OpenGL ES at the
/// next launch; [auto] says the game turned it on itself after a crash.
typedef GraphicsInfo = ({bool compat, bool auto, String active});

/// Talks to MainActivity's `wordsmith/diagnostics` channel. Everything
/// quietly comes back empty where there's no such channel (tests, other
/// platforms).
class Diagnostics {
  const Diagnostics();

  static const _channel = MethodChannel('wordsmith/diagnostics');

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('diagnostics $method: $e');
      return null;
    }
  }

  Future<String> device() async => await _call<String>('device') ?? defaultTargetPlatform.name;

  Future<CrashReport?> lastCrash() async {
    final raw = await _call<String>('lastCrash');
    if (raw == null) return null;
    try {
      return CrashReport.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  Future<GraphicsInfo?> graphics() async {
    final m = await _call<Map<Object?, Object?>>('graphics');
    if (m == null) return null;
    return (compat: m['compat'] == true, auto: m['auto'] == true, active: m['active'] as String? ?? 'vulkan');
  }

  Future<void> setCompat(bool on) => _call<void>('setCompat', on);
}

final diagnosticsProvider = Provider<Diagnostics>((_) => const Diagnostics());

final lastCrashProvider = FutureProvider<CrashReport?>((ref) => ref.watch(diagnosticsProvider).lastCrash());

final graphicsProvider = FutureProvider<GraphicsInfo?>((ref) => ref.watch(diagnosticsProvider).graphics());
