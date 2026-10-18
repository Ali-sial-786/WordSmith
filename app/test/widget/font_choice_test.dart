import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/profile.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/settings/font_picker.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/ui/theme/appearance.dart';
import 'package:wordsmith/ui/theme/theme.dart';

import '../fixtures/puzzles.dart';

Future<Store> _pumpSettings(WidgetTester tester, Map<String, Object> settings) async {
  SharedPreferences.setMockInitialValues({
    'profile.v1': jsonEncode({'userId': 'abc'}),
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false, ...settings}),
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
  await tester.binding.setSurfaceSize(const Size(412, 892));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(
        router: GoRouter(initialLocation: '/settings', routes: appRouter.configuration.routes),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

String? _familyOf(WidgetTester tester, String text) => tester.widget<Text>(find.text(text)).style?.fontFamily;

void main() {
  test('every font choice is bundled with the app', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    final bundled = {for (final f in manifest) (f as Map)['family']};
    for (final f in FontChoice.all) {
      for (final family in [f.display, f.letters, f.ui]) {
        expect(bundled, contains(family), reason: f.id);
      }
    }
    expect(FontChoice.all.map((f) => f.id).toSet(), hasLength(FontChoice.all.length));
  });

  test('players who never picked a font, or picked one that is gone, get the forge set', () {
    for (final s in [
      Settings.fromJson(const {}),
      Settings.fromJson(const {'font': 'gone'}),
    ]) {
      applyAppearance(s);
      expect(Fonts.choice, FontChoice.forge);
    }
    expect(Fonts.letters, 'Arvo');
    expect(Fonts.display, 'VollkornSC');
    expect(letterStyle(20).fontFamily, 'Arvo');
    expect(displayStyle(20).fontFamily, 'VollkornSC');
  });

  test('the text styles follow the font choice', () {
    addTearDown(() => Fonts.choice = FontChoice.forge);
    Fonts.choice = FontChoice.classic;
    expect(letterStyle(20).fontFamily, 'RobotoSlab');
    expect(letterStyle(20).fontWeight, FontWeight.w800);
    expect(letterStyle(20).fontVariations, [const FontVariation('wght', 800)]);
    expect(displayStyle(20).fontFamily, 'Cinzel');
    expect(displayStyle(20).letterSpacing, closeTo(1.2, 1e-9));
    expect(buildTheme().textTheme.bodyMedium?.fontFamily, 'NunitoSans');
    Fonts.choice = FontChoice.clear;
    expect(displayStyle(20).fontWeight, FontWeight.w800);
    expect(buildTheme().textTheme.bodyMedium?.fontFamily, 'AtkinsonHyperlegibleNext');
    // Another choice's samples, whatever the player's fonts.
    expect(letterStyle(20, font: FontChoice.guild).fontFamily, 'Texturina');
    expect(displayStyle(20, font: FontChoice.forge).fontFamily, 'VollkornSC');
  });

  testWidgets('a font picked in Settings is saved and used at once, with the picker kept in view', (tester) async {
    final store = await _pumpSettings(tester, {});
    expect(_familyOf(tester, 'Settings'), 'VollkornSC');
    await tester.scrollUntilVisible(find.text('Foundry'), 200);
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.byType(FontPicker)).dy;

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(store.loadSettings().font, 'clear');
    expect(Fonts.choice, FontChoice.clear);
    expect(Fonts.letters, 'AtkinsonHyperlegibleNext');
    // Every screen is built afresh in the new fonts.
    expect(_familyOf(tester, 'Settings'), 'AtkinsonHyperlegibleNext');
    expect(tester.getTopLeft(find.byType(FontPicker)).dy, closeTo(before, 1));
    final selected = find.byWidgetPredicate((w) => w is Semantics && w.properties.selected == true);
    expect(find.ancestor(of: find.text('Clear'), matching: selected), findsOneWidget);
    expect(find.ancestor(of: find.text('Forge'), matching: selected), findsNothing);
  });

  testWidgets('a saved font is used from the start', (tester) async {
    await _pumpSettings(tester, {'font': 'classic'});
    expect(Fonts.choice, FontChoice.classic);
    expect(_familyOf(tester, 'Settings'), 'Cinzel');
  });
}
