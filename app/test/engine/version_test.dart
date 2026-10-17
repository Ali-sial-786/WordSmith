import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/app_info.dart';
import 'package:wordsmith/game/daily_game.dart';
import 'package:wordsmith/net/push.dart';

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

  test('only well-formed invite notifications open a room', () {
    expect(inviteTarget({'type': 'invite', 'code': 'k7q2ab', 'mode': 'vs'}), (code: 'K7Q2AB', mode: 'vs'));
    expect(inviteTarget({'type': 'invite', 'code': 'K7Q2AB'}), (code: 'K7Q2AB', mode: 'coop'));
    expect(inviteTarget({'type': 'invite', 'code': 'K7Q2A0'}), isNull, reason: '0 is not in the alphabet');
    expect(inviteTarget({'type': 'other', 'code': 'K7Q2AB'}), isNull);
    expect(inviteTarget(null), isNull);
  });

  test("today's commission is the UTC day", () {
    expect(todayUtc(DateTime.utc(2026, 10, 17, 23, 59)), '2026-10-17');
    expect(todayUtc(DateTime.utc(2027, 1, 4, 0, 1)), '2027-01-04');
  });
}
