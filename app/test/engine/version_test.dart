import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/app_info.dart';
import 'package:wordsmith/game/daily_game.dart';

void main() {
  test('versions compare part by part', () {
    expect(compareVersions('0.2.0', '0.1.0'), greaterThan(0));
    expect(compareVersions('0.1.10', '0.1.9'), greaterThan(0));
    expect(compareVersions('0.1', '0.1.0'), 0);
    expect(compareVersions('1.0.0', '1.0.1'), lessThan(0));
  });

  test('daily dates read like a calendar', () {
    expect(prettyDate('2026-10-17'), 'Sat 17 Oct');
    expect(prettyDate('2027-01-04'), 'Mon 4 Jan');
    expect(prettyDate('nonsense'), 'nonsense');
  });
}
