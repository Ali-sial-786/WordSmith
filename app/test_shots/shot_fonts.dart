import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Loads every font in pubspec.yaml (as listed in the bundle's font manifest),
/// so shots draw with whichever fonts the player picked, plus the Material icons.
Future<void> loadShotFonts() async {
  final manifest = (jsonDecode(await rootBundle.loadString('FontManifest.json')) as List).cast<Map<String, dynamic>>();
  for (final family in manifest) {
    final name = family['family'] as String;
    if (name == 'MaterialIcons') continue;
    final loader = FontLoader(name);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
  final icons = File('/opt/sdk/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf').readAsBytesSync();
  await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.view(icons.buffer)))).load();
}
