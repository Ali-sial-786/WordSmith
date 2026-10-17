import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engine/masterworks.dart';

/// A Masterwork's name and story (assets/masterworks/masterworks.json).
class MasterworkInfo {
  const MasterworkInfo({required this.spec, required this.name, required this.blurb});

  final MasterworkSpec spec;
  final String name;
  final String blurb;

  String get id => spec.id;
  String get art => 'assets/masterworks/${spec.id}.svg';
}

/// Every Masterwork with plain names, until the real ones load.
final List<MasterworkInfo> plainMasterworks = [
  for (final spec in masterworkSpecs) MasterworkInfo(spec: spec, name: _titleCase(spec.id), blurb: ''),
];

/// Every Masterwork in build order. Falls back to plain names if the asset
/// can't be read, so the Armory always works.
final masterworkInfoProvider = FutureProvider<List<MasterworkInfo>>((ref) async {
  Map<String, Map<String, dynamic>> byId = const {};
  try {
    final raw = jsonDecode(await rootBundle.loadString('assets/masterworks/masterworks.json')) as Map;
    byId = {
      for (final item in (raw['items'] as List).cast<Map<String, dynamic>>()) item['id'] as String: item,
    };
  } on Object {
    // Plain names below.
  }
  return [
    for (final spec in masterworkSpecs)
      MasterworkInfo(
        spec: spec,
        name: byId[spec.id]?['name'] as String? ?? _titleCase(spec.id),
        blurb: byId[spec.id]?['blurb'] as String? ?? '',
      ),
  ];
}, retry: (_, _) => null);

String _titleCase(String id) => id[0].toUpperCase() + id.substring(1);
