import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
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

import '../fixtures/puzzles.dart';

const _apk = 'https://example.com/wordsmith-9.9.9.apk';

/// Stands in for AppUpdater.kt: downloads finish when the test says.
class _FakeUpdater extends AppUpdater {
  bool allowed = true;
  bool settingsOpened = false;
  final installs = <String>[];
  final downloads = <String>[];
  Completer<String> pending = Completer();
  void Function(int, int)? progress;

  @override
  bool get supported => true;

  @override
  Future<String> download(String url, String version, {void Function(int, int)? onProgress}) {
    downloads.add('$url $version');
    progress = onProgress;
    return pending.future;
  }

  @override
  Future<void> cancel() async {
    if (!pending.isCompleted) pending.completeError(const UpdateFailure('cancelled'));
  }

  @override
  Future<bool> canInstall() async => allowed;

  @override
  Future<void> allowInstalls() async => settingsOpened = true;

  @override
  Future<bool> install(String path) async {
    installs.add(path);
    return true;
  }
}

Future<void> _pumpApp(WidgetTester tester, _FakeUpdater updater, {String latest = '9.9.9', String? location}) async {
  SharedPreferences.setMockInitialValues({
    'settings.v1': jsonEncode({'reducedMotion': true, 'haptics': false}),
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
      appUpdaterProvider.overrideWithValue(updater),
      serverVersionProvider.overrideWith((_) async => (latest: latest, minSupported: '0.1.0', apk: _apk)),
    ],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(412, 892));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: WordsmithApp(
        router: GoRouter(initialLocation: location ?? '/', routes: appRouter.configuration.routes),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Lets sheets and snack bars animate in; the download's bar never settles
/// while it waits for its first bytes.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('the Hall offers a new version, downloads it and opens the installer', (tester) async {
    final updater = _FakeUpdater();
    await _pumpApp(tester, updater);

    expect(find.text('Wordsmith 9.9.9 is out!'), findsOneWidget);
    await tester.tap(find.text('Update now'));
    await _settle(tester);
    expect(find.text('Downloading 9.9.9'), findsOneWidget);
    expect(updater.downloads, ['$_apk 9.9.9']);

    updater.progress!(50 * 1024 * 1024, 100 * 1024 * 1024);
    await tester.pump();
    expect(find.text('50 of 100 MB'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.5);

    updater.pending.complete('/cache/updates/wordsmith-9.9.9.apk');
    await _settle(tester);
    expect(updater.installs, ['/cache/updates/wordsmith-9.9.9.apk']);
    expect(find.text('Install Wordsmith 9.9.9'), findsOneWidget);

    // Backed out of Android's prompt: try it again.
    await tester.tap(find.text('Install'));
    await _settle(tester);
    expect(updater.installs, hasLength(2));
  });

  testWidgets('asks for Android\'s leave to install, then carries on when back', (tester) async {
    final updater = _FakeUpdater()..allowed = false;
    await _pumpApp(tester, updater);

    await tester.tap(find.text('Update now'));
    await _settle(tester);
    updater.pending.complete('/cache/updates/wordsmith-9.9.9.apk');
    await _settle(tester);
    expect(find.text('One more step'), findsOneWidget);
    expect(updater.installs, isEmpty);

    await tester.tap(find.text('Open settings'));
    await _settle(tester);
    expect(updater.settingsOpened, isTrue);

    updater.allowed = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);
    expect(updater.installs, ['/cache/updates/wordsmith-9.9.9.apk']);
    expect(find.text('Install Wordsmith 9.9.9'), findsOneWidget);
  });

  testWidgets('a failed download says why and tries again', (tester) async {
    final updater = _FakeUpdater();
    await _pumpApp(tester, updater);

    await tester.tap(find.text('Update now'));
    await _settle(tester);
    updater.pending.completeError(const UpdateFailure('missing'));
    await _settle(tester);
    expect(find.text('Update paused'), findsOneWidget);
    expect(find.text('The new version is still on its way. Try again in a few minutes.'), findsOneWidget);

    updater.pending = Completer();
    await tester.tap(find.text('Try again'));
    await _settle(tester);
    expect(updater.downloads, hasLength(2));
    expect(find.text('Downloading 9.9.9'), findsOneWidget);

    // Cancelling closes the sheet and stops the download.
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(find.text('Downloading 9.9.9'), findsNothing);
    expect(updater.pending.isCompleted, isTrue);
  });

  testWidgets('Settings checks for updates on a tap', (tester) async {
    final updater = _FakeUpdater();
    await _pumpApp(tester, updater, latest: '0.0.1', location: '/settings');

    await tester.scrollUntilVisible(find.text('Tap to check for updates'), 200);
    await tester.pump(); // lay out the last scroll before tapping
    await tester.tap(find.text('Tap to check for updates'));
    await _settle(tester);
    expect(find.text('You have the latest version.'), findsOneWidget);
    expect(updater.downloads, isEmpty);
  });
}
