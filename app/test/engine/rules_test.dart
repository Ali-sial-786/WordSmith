import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/engine/heat.dart';
import 'package:wordsmith/engine/hints.dart';
import 'package:wordsmith/engine/pickups.dart';
import 'package:wordsmith/engine/progression.dart';
import 'package:wordsmith/engine/words.dart';

void main() {
  group('words', () {
    test('normalize and letter multiplicity', () {
      expect(normalizeWord(' t-e a r!'), 'TEAR');
      expect(canBeMadeFrom('TEAR', 'RTAE'), isTrue);
      expect(canBeMadeFrom('TEETH', 'TEHAT'), isFalse);
      expect(canBeMadeFrom('TEETH', 'TEHEA'), isFalse);
      expect(canBeMadeFrom('TEETH', 'TEHETT'), isTrue);
    });
  });

  group('progression', () {
    test('XP curve', () {
      expect(xpToNext(1), 60);
      expect(xpToNext(10), 150);
      expect(xpToNext(50), 550);
      final start = levelForTotalXp(0);
      expect((start.level, start.xpIntoLevel, start.xpForNext), (1, 0, 60));
      final two = levelForTotalXp(60);
      expect((two.level, two.xpIntoLevel, two.xpForNext), (2, 0, 70));
      final mid = levelForTotalXp(60 + 70 + 5);
      expect((mid.level, mid.xpIntoLevel), (3, 5));
    });

    test('ranks', () {
      expect(Rank.forLevel(1), Rank.apprentice);
      expect(Rank.forLevel(10), Rank.journeyman);
      expect(Rank.forLevel(24), Rank.journeyman);
      expect(Rank.forLevel(25), Rank.smith);
      expect(Rank.forLevel(119), Rank.grandmaster);
      expect(Rank.forLevel(500), Rank.legend);
    });

    test('level-up rewards', () {
      expect(levelUpRewards(1, 2), {HintKind.hammer: 1});
      expect(levelUpRewards(4, 5), {HintKind.hammer: 1, HintKind.chisel: 1});
      // Lv 10: +1 hammer, +1 chisel (5th level), rank-up bundle (hammer,
      // chisel; sparks not unlocked until 12).
      expect(levelUpRewards(9, 10), {HintKind.hammer: 2, HintKind.chisel: 2});
      expect(levelUpRewards(11, 12), {HintKind.hammer: 1});
      expect(levelUpRewards(19, 20), {
        HintKind.hammer: 1,
        HintKind.chisel: 1,
        HintKind.sparks: 1,
      });
      expect(levelUpRewards(1, 3), {HintKind.hammer: 2});
      expect(levelUpRewards(3, 3), isEmpty);
    });

    test('solo XP', () {
      expect(soloXp(bonusWords: 0), 10);
      expect(soloXp(bonusWords: 3), 13);
      expect(soloXp(bonusWords: 12), 15);
    });
  });

  test('heat from level', () {
    expect(Heat.forLevel(1), Heat.ember);
    expect(Heat.forLevel(5), Heat.ember);
    expect(Heat.forLevel(6), Heat.dullRed);
    expect(Heat.forLevel(34), Heat.orange);
    expect(Heat.forLevel(81), Heat.whiteHeat);
    expect(Heat.fromValue(3), Heat.cherryRed);
  });

  group('pickups match shared/pickups.md', () {
    test('hash and PRNG vectors', () {
      expect(fnv1a32(''), 0x811c9dc5);
      expect(fnv1a32('a'), 0xe40c292c);
      expect(fnv1a32('wordsmith'), 0xb0870248);
      final r = mulberry32(1);
      expect(r(), closeTo(0.6270739406, 1e-10));
      expect(r(), closeTo(0.0027357212, 1e-10));
      expect(r(), closeTo(0.5274470400, 1e-10));
    });

    List<Pickup> p(String user, String puzzle, int cells, int level) =>
        pickupsFor(
          userId: user,
          puzzleId: puzzle,
          cellCount: cells,
          level: level,
        );

    test('pickup vectors', () {
      expect(p('user-123', 'c-0010', 30, 20), [
        const Pickup(10, HintKind.chisel),
      ]);
      expect(p('user-123', 'c-0010', 30, 1), [
        const Pickup(10, HintKind.hammer),
      ]);
      expect(p('user-123', 'c-0032', 24, 3), [
        const Pickup(7, HintKind.hammer),
      ]);
      expect(p('abc', 'c-0001', 12, 1), isEmpty);
      expect(p('user-123', 'c-0012', 9, 50), [
        const Pickup(0, HintKind.hammer),
      ]);
      expect(p('friend-7', 'm-00033', 40, 30), [
        const Pickup(29, HintKind.hammer),
        const Pickup(2, HintKind.hammer),
      ]);
      expect(p('user-123', 'c-0074', 30, 12), [
        const Pickup(19, HintKind.sparks),
      ]);
      expect(p('user-123', 'c-0074', 30, 11), [
        const Pickup(19, HintKind.hammer),
      ]);
      expect(p('user-123', 'c-0146', 3, 12), [
        const Pickup(2, HintKind.hammer),
        const Pickup(0, HintKind.hammer),
      ]);
    });

    test('roughly one puzzle in five has a pickup', () {
      var hits = 0;
      for (var i = 1; i <= 2000; i++) {
        if (p('someone', 'c-${i.toString().padLeft(4, '0')}', 30, 20)
            .isNotEmpty) {
          hits++;
        }
      }
      expect(hits / 2000, inInclusiveRange(0.17, 0.23));
    });
  });
}
