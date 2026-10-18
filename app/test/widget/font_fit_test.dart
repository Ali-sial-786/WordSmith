import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/ui/theme/theme.dart';

import '../fixtures/puzzles.dart';

/// The real fonts (tests otherwise draw every glyph as a square), so wider
/// lettering shows up as overflow.
Future<void> _loadFonts() async {
  final manifest = (jsonDecode(await rootBundle.loadString('FontManifest.json')) as List).cast<Map<String, dynamic>>();
  for (final family in manifest) {
    if (family['family'] == 'MaterialIcons') continue;
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

/// Every font choice fits the main screens of a small phone.
void main() {
  setUpAll(_loadFonts);

  for (final font in FontChoice.all) {
    for (final location in ['/', '/play/1', '/chapters', '/profile', '/settings']) {
      testWidgets('$location fits in the ${font.name} fonts', (tester) async {
        SharedPreferences.setMockInitialValues({
          'profile.v1': jsonEncode({'userId': 'abc'}),
          'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false, 'font': font.id}),
        });
        final store = await Store.open();
        final container = ProviderContainer(
          overrides: [
            storeProvider.overrideWithValue(store),
            campaignProvider.overrideWithValue(
              Campaign.fromJson({
                'version': 1,
                'chapters': [
                  {'id': 'tin', 'name': 'Tin', 'first': 1, 'count': 1},
                ],
                'puzzles': [tearJson()],
              }),
            ),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(() => Fonts.choice = FontChoice.forge);
        await tester.binding.setSurfaceSize(const Size(360, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: WordsmithApp(
              router: GoRouter(initialLocation: location, routes: appRouter.configuration.routes),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(Fonts.choice, font);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
