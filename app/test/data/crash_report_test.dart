import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/data/diagnostics.dart';

void main() {
  CrashReport report(int at, int? updatedAt) => CrashReport.fromJson({
    'kind': 'crash',
    'at': at,
    'description': 'crash',
    'backend': 'vulkan',
    'trace': 'Wordsmith 0.8.0, thread update-download\njava.lang.IllegalStateException',
    'updatedAt': ?updatedAt,
  });

  test('says when a crash was in the version before this one', () {
    final text = report(1000, 5000).toText(device: 'phone');
    expect(text, contains('(the crash was in the version before)'));
    expect(text, contains('Trace:\nWordsmith 0.8.0, thread update-download'));
  });

  test('a crash after the install, or with no install time, says no more', () {
    expect(report(9000, 5000).toText(device: 'phone'), isNot(contains('version before')));
    expect(report(9000, null).toText(device: 'phone'), contains('Installed: unknown'));
  });
}
