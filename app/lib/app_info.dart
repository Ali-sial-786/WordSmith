/// Shown in Settings; keep in step with `version:` in pubspec.yaml.
const String appVersion = '0.3.2';

/// Compares dotted versions ("0.2.0" > "0.1.10"); missing parts count as 0.
int compareVersions(String a, String b) {
  final pa = a.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final pb = b.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}
