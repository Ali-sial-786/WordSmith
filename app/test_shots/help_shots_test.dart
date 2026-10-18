// Renders the Forge Hall's "?" and the guide it opens to PNGs with the real fonts, for eyeballing.
// Not part of the suite: flutter test test_shots/help_shots_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/auth/auth_service.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/hall/help_sheet.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/game/providers.dart';

import '../test/fixtures/fake_backend.dart';
import '../test/fixtures/puzzles.dart';

Future<void> _font(String family, Future<ByteData> data) async {
  final loader = FontLoader(family)..addFont(data);
  await loader.load();
}

/// The Hall of a signed-in smith partway through Bronze, on a [size] phone.
Future<void> _pumpHall(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues({
    'profile.v1': jsonEncode({'userId': 'abc', 'totalXp': 2600, 'campaignStage': 132}),
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  final auth = FakeAuth(
    signedIn: const AuthUser(uid: 'uid-ali', email: 'ali@example.com'),
  );
  final server = FakeServer()
    ..username = 'Ali_Smith'
    ..avatar = 'avatar_03'
    ..totalXp = 2600
    ..completed = 131
    ..dailyPuzzle = (tearJson()..['id'] = 'daily-2026-10-17')
    ..dailyStreak = 4;
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWithValue(store),
      campaignProvider.overrideWithValue(await tester.runAsync(Campaign.load) ?? (throw StateError('no campaign'))),
      authServiceProvider.overrideWithValue(auth),
      apiClientProvider.overrideWithValue(server.client(auth)),
    ],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(size);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(
        router: GoRouter(initialLocation: '/', routes: appRouter.configuration.routes),
      ),
    ),
  );
  await _wait(tester);
}

Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Future<void> _shot(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));

void main() {
  setUpAll(() async {
    await _font('Cinzel', rootBundle.load('assets/fonts/Cinzel-Variable.ttf'));
    await _font('RobotoSlab', rootBundle.load('assets/fonts/RobotoSlab-Variable.ttf'));
    await _font('NunitoSans', rootBundle.load('assets/fonts/NunitoSans-Variable.ttf'));
    final icons = File('/opt/sdk/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
        .readAsBytesSync();
    await _font('MaterialIcons', Future.value(ByteData.view(icons.buffer)));
  });

  for (final (tag, size) in [('412', const Size(412, 892)), ('360', const Size(360, 740))]) {
    testWidgets('hall with the help button at $tag', (tester) async {
      await _pumpHall(tester, size);
      await _shot('help_hall_$tag');
    });

    // The top of the guide, then each section's heading at the top, then the end.
    for (final (i, heading) in [null, 'Play with friends', 'Forge Board', 'Your smith', 'In a puzzle', ''].indexed) {
      testWidgets('help sheet at $tag, part ${i + 1}', (tester) async {
        await _pumpHall(tester, size);
        await tester.tap(find.byType(HelpButton));
        await _wait(tester);
        final list = find.descendant(of: find.byType(HelpSheet), matching: find.byType(Scrollable)).first;
        if (heading == '') {
          await tester.scrollUntilVisible(find.text('Why sign in?'), 300, scrollable: list);
          final position = tester.state<ScrollableState>(list).position;
          position.jumpTo(position.maxScrollExtent);
        } else if (heading != null) {
          final title = find.descendant(of: find.byType(HelpSheet), matching: find.text(heading));
          await tester.scrollUntilVisible(title, 300, scrollable: list);
          await tester.ensureVisible(title);
        }
        await _wait(tester);
        await _shot('help_sheet_${tag}_${i + 1}');
      });
    }
  }
}
