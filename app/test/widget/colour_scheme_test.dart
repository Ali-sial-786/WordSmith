import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/features/settings/scheme_picker.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/ui/theme/appearance.dart';
import 'package:wordsmith/ui/theme/palette.dart';
import 'package:wordsmith/ui/theme/theme.dart';
import 'package:wordsmith/ui/widgets/forge_frame.dart';

import '../fixtures/puzzles.dart';

double _contrast(Color a, Color b) {
  final (la, lb) = (a.computeLuminance(), b.computeLuminance());
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

Future<ProviderContainer> _container({String? scheme}) async {
  SharedPreferences.setMockInitialValues({
    'profile.v1': jsonEncode({'userId': 'abc'}),
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false, 'colorScheme': ?scheme}),
  });
  final store = await Store.open();
  return ProviderContainer(
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
}

Future<void> _pumpApp(WidgetTester tester, ProviderContainer container, String location) async {
  await tester.binding.setSurfaceSize(const Size(412, 892));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(
        router: GoRouter(initialLocation: location, routes: appRouter.configuration.routes),
      ),
    ),
  );
  await _settle(tester);
}

/// Some screens animate for ever (the swipe guide), so no pumpAndSettle.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  tearDown(() => Palette.scheme = PaletteScheme.forge);

  test('every scheme has its own id and readable text', () {
    expect(PaletteScheme.all.map((s) => s.id).toSet(), hasLength(PaletteScheme.all.length));
    expect(PaletteScheme.all.length, 10);
    expect(PaletteScheme.all.where((s) => s.isLight).length, greaterThan(2), reason: 'a few light schemes');
    for (final s in PaletteScheme.all) {
      for (final (name, ground) in [('background', s.forgeBlack), ('panel', s.soot)]) {
        expect(_contrast(s.whiteHeat, ground), greaterThan(7), reason: '${s.id}: text on $name');
        expect(_contrast(s.steel, ground), greaterThan(4.5), reason: '${s.id}: secondary text on $name');
        expect(_contrast(s.molten, ground), greaterThan(4.5), reason: '${s.id}: highlighted text on $name');
        // Links, typed text, "Delete account" and reward lines.
        for (final (accent, c) in [
          ('ember', s.ember),
          ('gold', s.gold),
          ('red', s.quenchRed),
          ('green', s.verdigris),
        ]) {
          expect(_contrast(c, ground), greaterThan(3.5), reason: '${s.id}: $accent text on $name');
        }
      }
      // Feed lines in the players' colours.
      Palette.scheme = s;
      for (final c in Palette.players) {
        expect(_contrast(Palette.legible(c), s.forgeBlack), greaterThan(3), reason: '${s.id}: player $c');
      }
      for (final face in [s.plate.$1, s.plate.$2]) {
        expect(_contrast(s.onAccent, face), greaterThan(4.5), reason: '${s.id}: text on an accent button');
      }
    }
  });

  test("a light scheme's pale metal, mold hollows and scene shadows take its own hue", () {
    // [m] (a colour matrix) applied to [c].
    Color through(List<double> m, Color c) {
      double row(int i) => (m[i] * c.r + m[i + 1] * c.g + m[i + 2] * c.b) * 255 + m[i + 4];
      return Color.fromARGB(
        255,
        row(0).round().clamp(0, 255),
        row(5).round().clamp(0, 255),
        row(10).round().clamp(0, 255),
      );
    }

    // The shading of the renders' iron, and a scene's shadows.
    const iron = Color(0xFF404040);
    const shadow = Color(0xFF202020);
    for (final (s, cool) in [
      (PaletteScheme.gilded, false),
      (PaletteScheme.parchment, false),
      (PaletteScheme.roseGold, false),
      (PaletteScheme.frost, true),
    ]) {
      Palette.scheme = s;
      for (final (what, c) in [
        ('anvil', through(SchemeFilters.iron()!, iron)),
        ('scene shadow', through(SchemeFilters.scene()!, shadow)),
        ('mold hollow', Palette.recess.top),
      ]) {
        expect(c.b > c.r, cool, reason: '${s.id}: $what is ${cool ? 'cool' : 'warm'}');
        expect(c.computeLuminance(), lessThan(s.forgeBlack.computeLuminance()), reason: '${s.id}: $what shows');
      }
    }
  });

  test('a picked scheme is saved, and applying it changes the colours, theme and system bars', () async {
    final container = await _container();
    addTearDown(container.dispose);
    expect(container.read(settingsProvider).colorScheme, 'forge');

    container.read(settingsProvider.notifier).update((s) => s.copyWith(colorScheme: 'gilded'));
    await Future<void>.delayed(Duration.zero);
    final saved = (await Store.open()).loadSettings();
    expect(saved.colorScheme, 'gilded');

    applyAppearance(saved);
    expect(Palette.scheme, PaletteScheme.gilded);
    expect(Palette.ember, PaletteScheme.gilded.ember);
    expect(Palette.forgeBlack, PaletteScheme.gilded.forgeBlack);
    expect(buildTheme().colorScheme.brightness, Brightness.light);
    expect(buildTheme().scaffoldBackgroundColor, PaletteScheme.gilded.forgeBlack);
    expect(systemBarStyle().statusBarIconBrightness, Brightness.dark);
    expect(SchemeFilters.iron(), isNotNull);

    applyAppearance(saved.copyWith(colorScheme: 'starmetal'));
    expect(Palette.molten, PaletteScheme.starmetal.molten);
    expect(buildTheme().colorScheme.brightness, Brightness.dark);
    expect(systemBarStyle().statusBarIconBrightness, Brightness.light);

    // A scheme this version doesn't know (from a newer one, say) is the forge's.
    applyAppearance(saved.copyWith(colorScheme: 'mithril'));
    expect(Palette.scheme, PaletteScheme.forge);
    expect(SchemeFilters.iron(), isNull, reason: 'the forge shows its renders as they are');
  });

  testWidgets('picking each swatch in Settings applies it at once and keeps the page where it was', (tester) async {
    final container = await _container();
    addTearDown(container.dispose);
    await _pumpApp(tester, container, '/settings');
    const scrolled = 200.0;
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(scrolled);
    await tester.pump();

    for (final s in [...PaletteScheme.all.skip(1), PaletteScheme.forge]) {
      await tester.tap(find.descendant(of: find.byType(SchemePicker), matching: find.text(s.name)));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(Palette.scheme, s);
      expect(container.read(settingsProvider).colorScheme, s.id);
      expect(Theme.of(tester.element(find.byType(SchemePicker))).scaffoldBackgroundColor, s.forgeBlack);
      // Settings was built afresh in the new colours, at the same place.
      expect(tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels, closeTo(scrolled, 1));
    }
  });

  testWidgets('the picker shows every scheme at once, in two rows of five, even on a small phone', (tester) async {
    final container = await _container();
    addTearDown(container.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final width in [320.0, 412.0]) {
      await tester.binding.setSurfaceSize(Size(width, 640));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(),
            home: const Scaffold(body: SchemePicker()),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: '$width');
      final names = [for (final s in PaletteScheme.all) tester.getRect(find.text(s.name))];
      expect(names.map((r) => r.top.round()).toSet(), hasLength(2), reason: '$width: two rows');
      expect(names.map((r) => r.height.toStringAsFixed(1)).toSet(), hasLength(1), reason: '$width: names at one size');
      for (final row in [names.take(5).toList(), names.skip(5).toList()]) {
        expect(row, hasLength(5));
        for (var i = 0; i < row.length; i++) {
          expect(row[i].left, greaterThanOrEqualTo(0), reason: '$width');
          expect(row[i].right, lessThanOrEqualTo(width), reason: '$width');
          if (i > 0) expect(row[i].left, greaterThanOrEqualTo(row[i - 1].right), reason: '$width: names apart');
        }
      }
    }
  });

  testWidgets('a scheme picked in Settings repaints the Hall underneath', (tester) async {
    final container = await _container();
    addTearDown(container.dispose);
    await _pumpApp(tester, container, '/');
    // The forge draws its frames as rendered; other schemes recolour each one.
    final before = find.byType(ColorFiltered).evaluate().length;
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/settings');
    await _settle(tester);
    await tester.scrollUntilVisible(find.byType(SchemePicker), 200);
    await tester.tap(find.descendant(of: find.byType(SchemePicker), matching: find.text('Steel')));
    await _settle(tester);
    await tester.pageBack();
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(SchemePicker), findsNothing);
    expect(find.byType(ColorFiltered).evaluate().length, greaterThan(before + 5));
  });

  for (final s in PaletteScheme.all) {
    testWidgets('${s.name}: the main screens build without errors', (tester) async {
      for (final location in ['/', '/play/1', '/chapters', '/profile', '/settings']) {
        final container = await _container(scheme: s.id);
        await _pumpApp(tester, container, location);
        expect(tester.takeException(), isNull, reason: location);
        expect(Palette.scheme, s);
        // Unmount before the container goes.
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      }
    });
  }

  testWidgets('frames and round buttons draw in every scheme', (tester) async {
    for (final s in PaletteScheme.all) {
      Palette.scheme = s;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Column(
              children: [
                for (final kind in ForgeFrameKind.values)
                  SizedBox(width: 200, height: 70, child: ForgeFrame(kind: kind)),
                const SizedBox.square(dimension: 54, child: KitImage('assets/ui/round_active.png', hot: true)),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: s.id);
      // Recoloured schemes draw each kit piece's face over its frame.
      expect(find.byType(ColorFiltered), s.asRendered ? findsNothing : findsWidgets);
    }
  });
}
