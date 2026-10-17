import 'package:flutter_test/flutter_test.dart';
import 'package:wordsmith/data/campaign.dart';

import '../fixtures/puzzles.dart';

void main() {
  test('the Master Forge goes round the campaign again (shared/master-forge.md)', () {
    final campaign = Campaign.fromJson({
      'version': 1,
      'chapters': [
        {'id': 'tin', 'name': 'Tin', 'first': 1, 'count': 2},
        {'id': 'copper', 'name': 'Copper', 'first': 3, 'count': 1},
      ],
      'puzzles': [
        tearJson(),
        {...tearJson(), 'id': 'c-0002'},
        {...tearJson(), 'id': 'c-0003'},
      ],
    });
    expect((campaign.stageCount, campaign.maxStage), (3, 30));
    expect(campaign.isMaster(3), isFalse);
    expect([for (final s in [4, 5, 6, 7, 30]) campaign.baseStage(s)], [1, 2, 3, 1, 3]);
    expect(campaign.puzzle(5).id, 'c-0002');
    expect(campaign.chapterFor(3).id, 'copper');
    final master = campaign.chapterFor(4);
    expect((master.id, master.first, master.last), ('master', 4, 30));
  });
}
