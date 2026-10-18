// Renders the in-app update's screens to PNGs with the real fonts, for eyeballing.
// Not part of the suite: flutter test test_shots/update_shots_test.dart --update-goldens
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/app.dart';
import 'package:wordsmith/data/campaign.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/update/app_updater.dart';

import 'shot_fonts.dart';

class _Updater extends AppUpdater {
  _Updater({this.allowed = true});

  final bool allowed;
  final pending = Completer<String>();
  void Function(int, int)? progress;

  @override
  bool get supported => true;

  @override
  Future<String> download(String url, String version, {void Function(int, int)? onProgress}) {
    progress = onProgress;
    return pending.future;
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<bool> canInstall() async => allowed;

  @override
  Future<void> allowInstalls() async {}

  @override
  Future<bool> install(String path) async => true;
}

Future<void> _pump(WidgetTester tester, _Updater updater, String location) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
  });
  final store = await Store.open();
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWithValue(store),
      campaignProvider.overrideWithValue(await tester.runAsync(Campaign.load) ?? (throw StateError('no campaign'))),
      appUpdaterProvider.overrideWithValue(updater),
      serverVersionProvider.overrideWith(
        (_) async => (latest: '9.9.9', minSupported: '0.1.0', apk: 'https://example.com/wordsmith-9.9.9.apk'),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(412, 892));
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(
        router: GoRouter(initialLocation: location, routes: appRouter.configuration.routes),
      ),
    ),
  );
  await _wait(tester);
}

Future<void> _wait(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _shot(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));

void main() {
  setUpAll(loadShotFonts);

  testWidgets('update banner', (tester) async {
    await _pump(tester, _Updater(), '/');
    await _shot('update_banner');
  });

  testWidgets('update downloading', (tester) async {
    final updater = _Updater();
    await _pump(tester, updater, '/');
    await tester.tap(find.text('Update now'));
    await _wait(tester);
    updater.progress!(43 * 1024 * 1024, 103 * 1024 * 1024);
    await tester.pump();
    await _shot('update_downloading');
  });

  testWidgets('update allow', (tester) async {
    final updater = _Updater(allowed: false);
    await _pump(tester, updater, '/');
    await tester.tap(find.text('Update now'));
    await _wait(tester);
    updater.pending.complete('/x.apk');
    await _wait(tester);
    await _shot('update_allow');
  });

  testWidgets('update installing', (tester) async {
    final updater = _Updater();
    await _pump(tester, updater, '/');
    await tester.tap(find.text('Update now'));
    await _wait(tester);
    updater.pending.complete('/x.apk');
    await _wait(tester);
    await _shot('update_installing');
  });

  testWidgets('update settings', (tester) async {
    await _pump(tester, _Updater(), '/settings');
    await tester.scrollUntilVisible(find.text('Version'), 300);
    await _wait(tester);
    await _shot('update_settings');
  });
}
