import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wordsmith/auth/auth_service.dart';
import 'package:wordsmith/data/store.dart';
import 'package:wordsmith/engine/hints.dart';
import 'package:wordsmith/game/account.dart';
import 'package:wordsmith/game/providers.dart';
import 'package:wordsmith/net/api_client.dart';

import '../fixtures/fake_backend.dart';

Future<(ProviderContainer, FakeAuth, FakeServer, Store)> _setUp({
  Map<String, Object> prefs = const {},
  FakeAuth? auth,
}) async {
  SharedPreferences.setMockInitialValues({
    'profile.v1': jsonEncode({'userId': 'install-abc'}),
    ...prefs,
  });
  final store = await Store.open();
  final fakeAuth = auth ?? FakeAuth();
  final server = FakeServer();
  final container = ProviderContainer(
    overrides: [
      storeProvider.overrideWithValue(store),
      authServiceProvider.overrideWithValue(fakeAuth),
      apiClientProvider.overrideWithValue(server.client(fakeAuth)),
    ],
  );
  addTearDown(container.dispose);
  container.listen(accountProvider, (_, _) {});
  return (container, fakeAuth, server, store);
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('without a server the account is unavailable', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await Store.open();
    final c = ProviderContainer(overrides: [storeProvider.overrideWithValue(store)]);
    addTearDown(c.dispose);
    expect(c.read(accountProvider).phase, AccountPhase.unavailable);
  });

  test('sign up, pick a name, and become ready', () async {
    final (c, auth, server, _) = await _setUp();
    await _settle();
    expect(c.read(accountProvider).phase, AccountPhase.signedOut);

    await c.read(accountProvider.notifier).signUp('ali@example.com', 'secret1');
    await _settle();
    expect(c.read(accountProvider).phase, AccountPhase.needsSetup);

    await expectLater(
      c.read(accountProvider.notifier).setup('taken', 'avatar_02'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'username_taken')),
    );

    await c.read(accountProvider.notifier).setup('Ali', 'avatar_03');
    await _settle();
    final state = c.read(accountProvider);
    expect(state.phase, AccountPhase.ready);
    expect(state.server?.username, 'Ali');
    expect(c.read(profileProvider).userId, 'uid-ali@example.com',
        reason: 'new puzzles seed pickups with the account id');
  });

  test('offline solo results sync and the server profile is taken', () async {
    final (c, auth, server, store) = await _setUp();
    server.username = 'Ali';
    await store.enqueueSync({
      'stage': 1,
      'puzzleId': 'c-0001',
      'foundWords': ['FEAR'],
      'bonusWords': <String>[],
      'hintsUsed': {'hammer': 1},
      'pickups': <Object>[],
      'pickupSeed': 'install-abc',
      'durationMs': 9000,
      'completedAt': 1,
    });
    auth.passwords['ali@example.com'] = 'secret1';
    await c.read(accountProvider.notifier).signIn('ali@example.com', 'secret1');
    await _settle();

    expect(c.read(accountProvider).phase, AccountPhase.ready);
    expect(server.synced.single['pickupSeed'], 'install-abc');
    expect(store.loadSyncQueue(), isEmpty);
    final profile = c.read(profileProvider);
    expect(profile.totalXp, 10);
    expect(profile.campaignStage, 2);
    expect(profile.hintCount(HintKind.hammer), 2);
  });

  test('a puzzle in progress keeps its hint use and bonus words on top of the server profile', () async {
    final saved = {
      'stage': 3,
      'puzzleId': 'c-0003',
      'letters': 'ABCD',
      'found': <int>[],
      'auto': <int>[],
      'revealed': <Object>[],
      'bonus': ['ONE', 'TWO'],
      'pickups': [
        {'cell': 0, 'kind': 'chisel'},
      ],
      'collected': [0],
      'hintsUsed': {'hammer': 2},
      'elapsedMs': 1000,
      'pickupSeed': 'install-abc',
    };
    final (c, auth, server, _) = await _setUp(prefs: {'saved_puzzle.v1': jsonEncode(saved)});
    server
      ..username = 'Ali'
      ..scrapBin = 9
      ..hints = {'hammer': 5, 'chisel': 0, 'sparks': 0};
    auth.passwords['a@b.c'] = 'secret1';
    await c.read(accountProvider.notifier).signIn('a@b.c', 'secret1');
    await _settle();

    final p = c.read(profileProvider);
    // 5 on the server − 2 used + 1 smelted from the Scrap Bin (9 + 2 bonus words).
    expect(p.hintCount(HintKind.hammer), 4);
    expect(p.hintCount(HintKind.chisel), 1, reason: 'collected pickup');
    expect(p.scrapBin, 1);
  });

  test('when the server is down the player keeps playing solo', () async {
    final (c, auth, server, _) = await _setUp();
    server.down = true;
    auth.passwords['a@b.c'] = 'secret1';
    await c.read(accountProvider.notifier).signIn('a@b.c', 'secret1');
    await _settle();
    expect(c.read(accountProvider).phase, AccountPhase.failed);
    expect(c.read(accountProvider).error, contains("Can't reach"));

    server.down = false;
    server.username = 'Ali';
    await c.read(accountProvider.notifier).retry();
    await _settle();
    expect(c.read(accountProvider).phase, AccountPhase.ready);
  });

  test('wrong password is reported by the sign-in service', () async {
    final (c, _, _, _) = await _setUp();
    await expectLater(
      c.read(accountProvider.notifier).signIn('nobody@example.com', 'nope'),
      throwsA(isA<AuthFailure>()),
    );
  });

  test('deleting the account clears the server, sign-in and this phone', () async {
    final (c, auth, server, store) = await _setUp();
    server.username = 'Ali';
    auth.passwords['a@b.c'] = 'secret1';
    await c.read(accountProvider.notifier).signIn('a@b.c', 'secret1');
    await _settle();

    await expectLater(
      c.read(accountProvider.notifier).deleteAccount(password: 'wrong'),
      throwsA(isA<AuthFailure>()),
    );
    expect(server.deletedMe, isFalse, reason: 'nothing deleted without the password');

    await c.read(accountProvider.notifier).deleteAccount(password: 'secret1');
    expect(server.deletedMe, isTrue);
    expect(auth.deleted, isTrue);
    expect(c.read(accountProvider).phase, AccountPhase.signedOut);
    expect(c.read(profileProvider).userId, isNot('uid-a@b.c'));
    expect(store.loadSyncQueue(), isEmpty);
  });

  test('Continue with Google signs up a new smith, and backing out does nothing', () async {
    final (c, auth, server, _) = await _setUp();
    await _settle();

    expect(await c.read(accountProvider.notifier).signInWithGoogle(), isFalse);
    await _settle();
    expect(c.read(accountProvider).phase, AccountPhase.signedOut);

    auth.googleEmail = 'sam@gmail.com';
    expect(await c.read(accountProvider.notifier).signInWithGoogle(), isTrue);
    await _settle();
    expect(c.read(accountProvider).phase, AccountPhase.needsSetup);
    expect(c.read(accountProvider).user?.usesPassword, isFalse);

    await c.read(accountProvider.notifier).setup('Sam', 'avatar_04');
    await _settle();
    expect(c.read(accountProvider).phase, AccountPhase.ready);
  });

  test('a Google account confirms with Google before it is deleted', () async {
    final (c, auth, server, _) = await _setUp();
    server.username = 'Sam';
    auth.googleEmail = 'sam@gmail.com';
    await c.read(accountProvider.notifier).signInWithGoogle();
    await _settle();

    auth.googleEmail = null; // backs out of the picker
    await expectLater(
      c.read(accountProvider.notifier).deleteAccount(),
      throwsA(isA<AuthFailure>()),
    );
    expect(server.deletedMe, isFalse);

    auth.googleEmail = 'sam@gmail.com';
    await c.read(accountProvider.notifier).deleteAccount();
    expect(server.deletedMe, isTrue);
    expect(c.read(accountProvider).phase, AccountPhase.signedOut);
  });
}
