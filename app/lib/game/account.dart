import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_service.dart';
import '../net/api_client.dart';
import '../net/hub_client.dart';
import '../net/models.dart';
import 'providers.dart';

/// Overridden in main() from the build's settings (net/config.dart).
final authServiceProvider = Provider<AuthService>((_) => const DisabledAuthService());
final apiClientProvider = Provider<ApiClient?>((_) => null);
final hubClientProvider = Provider<HubClient?>((_) => null);

final accountProvider = NotifierProvider<AccountController, AccountState>(
  AccountController.new,
);

enum AccountPhase {
  /// This build has no sign-in or server configured.
  unavailable,
  signedOut,
  loading,

  /// Signed in, but no username yet.
  needsSetup,
  ready,

  /// Signed in, but the server couldn't be reached; solo play carries on.
  failed,
}

class AccountState {
  const AccountState({
    required this.phase,
    this.user,
    this.server,
    this.friends = const FriendsList(),
    this.presence = const {},
    this.invites = const [],
    this.error,
    this.syncing = false,
  });

  final AccountPhase phase;
  final AuthUser? user;
  final ServerProfile? server;
  final FriendsList friends;

  /// Friend user id → `online`, `solo`, `in_room:<CODE>` or `offline`.
  final Map<String, String> presence;
  final List<HubInvite> invites;
  final String? error;
  final bool syncing;

  bool get isReady => phase == AccountPhase.ready;

  int get friendsOnline => friends.friends
      .where((f) => (presence[f.id] ?? 'offline') != 'offline')
      .length;

  AccountState copyWith({
    AccountPhase? phase,
    AuthUser? user,
    ServerProfile? server,
    FriendsList? friends,
    Map<String, String>? presence,
    List<HubInvite>? invites,
    String? error,
    bool clearError = false,
    bool? syncing,
  }) => AccountState(
    phase: phase ?? this.phase,
    user: user ?? this.user,
    server: server ?? this.server,
    friends: friends ?? this.friends,
    presence: presence ?? this.presence,
    invites: invites ?? this.invites,
    error: clearError ? null : error ?? this.error,
    syncing: syncing ?? this.syncing,
  );
}

/// Signs in, picks a name, keeps the phone's progress in step with the
/// server, and tracks friends and who's online.
class AccountController extends Notifier<AccountState> {
  StreamSubscription<AuthUser?>? _authSub;
  StreamSubscription<HubEvent>? _hubSub;
  bool _syncAgain = false;
  String? _loadingUid;

  AuthService get _auth => ref.read(authServiceProvider);
  ApiClient? get _api => ref.read(apiClientProvider);
  HubClient? get _hub => ref.read(hubClientProvider);

  @override
  AccountState build() {
    ref.onDispose(() {
      _authSub?.cancel();
      _hubSub?.cancel();
    });
    if (_api == null) return const AccountState(phase: AccountPhase.unavailable);
    // The auth stream starts with the current user, which triggers the load.
    _authSub = _auth.changes.listen(_onUser);
    final user = _auth.current;
    return AccountState(
      phase: user == null ? AccountPhase.signedOut : AccountPhase.loading,
      user: user,
    );
  }

  Future<void> _onUser(AuthUser? user) async {
    if (!ref.mounted) return;
    if (user == null) {
      // Set the state before any await, so a sign-in that lands meanwhile
      // can't be overwritten by this older event.
      state = const AccountState(phase: AccountPhase.signedOut);
      await _stopHub();
      return;
    }
    if (_loadingUid == user.uid) return;
    if (state.user?.uid == user.uid &&
        (state.phase == AccountPhase.ready || state.phase == AccountPhase.needsSetup)) {
      return;
    }
    state = AccountState(phase: AccountPhase.loading, user: user);
    _loadingUid = user.uid;
    try {
      await _load(user.uid);
    } finally {
      _loadingUid = null;
    }
  }

  /// Whether [uid] is still the signed-in player after an await.
  bool _current(String uid) => ref.mounted && state.user?.uid == uid;

  Future<void> _load(String uid) async {
    try {
      final profile = await _api!.me();
      if (!_current(uid)) return;
      if (profile.needsSetup) {
        state = state.copyWith(phase: AccountPhase.needsSetup, server: profile, clearError: true);
      } else {
        await _becomeReady(profile);
      }
    } on ApiException catch (e) {
      if (_current(uid)) state = state.copyWith(phase: AccountPhase.failed, error: e.friendly);
    }
  }

  /// Tries again after a failure.
  Future<void> retry() async {
    final uid = state.user?.uid;
    if (uid == null) return;
    state = state.copyWith(phase: AccountPhase.loading, clearError: true);
    await _load(uid);
  }

  // ---- Sign-in (errors surface as AuthFailure for the form to show) ----

  Future<void> signIn(String email, String password) => _auth.signIn(email, password);
  Future<void> signUp(String email, String password) => _auth.signUp(email, password);
  Future<void> resetPassword(String email) => _auth.resetPassword(email);
  Future<void> signOut() => _auth.signOut();

  /// Picks the username and avatar. Throws [ApiException] (e.g. taken).
  Future<void> setup(String username, String avatar) async {
    final profile = await _api!.setup(username, avatar);
    await _becomeReady(profile);
  }

  Future<void> changeAvatar(String avatar) async {
    final name = state.server?.username;
    if (name == null) return;
    final profile = await _api!.setup(name, avatar);
    state = state.copyWith(server: profile);
  }

  Future<void> _becomeReady(ServerProfile profile) async {
    state = state.copyWith(phase: AccountPhase.ready, server: profile, clearError: true);
    await sync();
    if (!state.isReady) return;
    unawaited(refreshFriends());
    unawaited(_startHub());
  }

  // ---- Solo progress ----

  /// Sends finished solo puzzles to the server and takes its profile as the
  /// truth. Safe to call any time; it does nothing unless ready.
  Future<void> sync() async {
    if (!state.isReady) return;
    if (state.syncing) {
      _syncAgain = true;
      return;
    }
    state = state.copyWith(syncing: true);
    final store = ref.read(storeProvider);
    try {
      do {
        _syncAgain = false;
        var server = state.server!;
        final queue = store.loadSyncQueue();
        for (var i = 0; i < queue.length; i += 100) {
          final batch = queue.sublist(i, (i + 100).clamp(0, queue.length));
          final outcome = await _api!.soloSync(batch);
          await store.dropSynced(batch.length);
          server = outcome.profile;
          if (outcome.rejected.isNotEmpty) {
            debugPrint('sync: server declined ${outcome.rejected}');
          }
        }
        if (queue.isEmpty) server = await _api!.me();
        if (!ref.mounted || !state.isReady) return;
        ref.read(profileProvider.notifier).applyServer(server, pending: store.loadSavedPuzzle());
        state = state.copyWith(server: server, clearError: true);
      } while (_syncAgain);
    } on ApiException catch (e) {
      if (ref.mounted) state = state.copyWith(error: e.friendly);
    } finally {
      if (ref.mounted) state = state.copyWith(syncing: false);
    }
  }

  // ---- Friends ----

  Future<void> refreshFriends() async {
    if (!state.isReady) return;
    try {
      final friends = await _api!.friends();
      if (ref.mounted && state.isReady) state = state.copyWith(friends: friends);
    } on ApiException catch (e) {
      if (ref.mounted) state = state.copyWith(error: e.friendly);
    }
  }

  /// Returns true if it became a friendship right away (they'd asked too).
  Future<bool> requestFriend(String username) async {
    final status = await _api!.requestFriend(username.trim());
    await refreshFriends();
    return status == 'accepted';
  }

  Future<void> respondFriend(String userId, {required bool accept}) async {
    await _api!.respondFriend(userId, accept: accept);
    await refreshFriends();
  }

  Future<void> removeFriend(String userId) async {
    await _api!.removeFriend(userId);
    await refreshFriends();
  }

  Future<List<LeaderboardEntry>> leaderboard() => _api!.leaderboard();

  // ---- Presence ----

  /// `online` in menus, `solo` while forging a campaign puzzle.
  void setStatus(String status) => _hub?.setStatus(status);

  void dismissInvite(HubInvite invite) =>
      state = state.copyWith(invites: [...state.invites]..remove(invite));

  Future<void> _startHub() async {
    final hub = _hub;
    if (hub == null) return;
    await _hubSub?.cancel();
    _hubSub = hub.events.listen(_onHubEvent);
    await hub.start();
  }

  Future<void> _stopHub() async {
    await _hubSub?.cancel();
    _hubSub = null;
    await _hub?.stop();
  }

  void _onHubEvent(HubEvent event) {
    if (!ref.mounted) return;
    switch (event) {
      case HubPresence(:final userId, :final status):
        state = state.copyWith(presence: {...state.presence, userId: status});
        if (!state.friends.friends.any((f) => f.id == userId)) unawaited(refreshFriends());
      case HubInvite():
        state = state.copyWith(invites: [...state.invites, event]);
      case HubOpenRooms() || HubError():
        break;
    }
  }

  // ---- Account deletion ----

  /// Deletes the account everywhere and resets this phone. Email accounts
  /// must confirm their [password] first.
  Future<void> deleteAccount(String password) async {
    await _auth.reauthenticate(password);
    await _api!.deleteMe();
    await _stopHub();
    await _auth.deleteUser();
    await ref.read(profileProvider.notifier).resetLocal();
    state = const AccountState(phase: AccountPhase.signedOut);
  }
}
