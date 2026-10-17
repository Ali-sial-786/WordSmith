import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_service.dart';
import '../net/api_client.dart';
import '../net/hub_client.dart';
import '../net/models.dart';
import '../net/push.dart';
import '../net/room_client.dart';
import '../video/video_call.dart';
import 'providers.dart';

/// Overridden in main() from the build's settings (net/config.dart).
final authServiceProvider = Provider<AuthService>((_) => const DisabledAuthService());
final apiClientProvider = Provider<ApiClient?>((_) => null);
final hubClientProvider = Provider<HubClient?>((_) => null);

/// Opens the connection to a room by code (null without a server).
final roomClientFactoryProvider = Provider<RoomClient Function(String code)?>((_) => null);

/// Invite notifications; overridden in main() when Firebase is set up.
final pushServiceProvider = Provider<PushService>((_) => const DisabledPushService());

/// Today's Daily Commission, once signed in (null otherwise). Invalidated after
/// forging it.
final dailyProvider = FutureProvider<DailyInfo?>(
  (ref) async {
    final ready = ref.watch(accountProvider.select((a) => a.isReady));
    final api = ref.read(apiClientProvider);
    if (!ready || api == null) return null;
    return api.daily();
  },
  // The daily screen has its own "Try again"; no automatic retries.
  retry: (_, _) => null,
);

/// The server's `/v1/version`: the newest app version and the oldest one it
/// still plays online with. Null offline or without a server.
final serverVersionProvider = FutureProvider<({String latest, String minSupported})?>(
  (ref) async {
    final api = ref.read(apiClientProvider);
    if (api == null) return null;
    try {
      final v = await api.version();
      return (latest: v['latest'] as String? ?? '0.0.0', minSupported: v['minSupported'] as String? ?? '0.0.0');
    } on ApiException {
      return null;
    }
  },
  retry: (_, _) => null,
);

/// Makes a room's video chat for this player (user ID); null without online play.
final videoCallFactoryProvider = Provider<VideoCall Function(String me)?>((_) => null);

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
    this.openRooms = const [],
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

  /// Friends' rooms that can be joined.
  final List<OpenRoom> openRooms;
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
    List<OpenRoom>? openRooms,
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
    openRooms: openRooms ?? this.openRooms,
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
  bool get googleAvailable => _auth.googleAvailable;

  /// Returns false if the player backed out of Google's account picker.
  Future<bool> signInWithGoogle() => _auth.signInWithGoogle();
  Future<void> signOut() async {
    // While still signed in, so the server can forget this phone.
    await _unregisterPush();
    await _auth.signOut();
  }

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
    unawaited(_registerPush());
  }

  // ---- Invite notifications ----

  String? _pushToken;
  StreamSubscription<String>? _pushRefresh;

  PushService get _push => ref.read(pushServiceProvider);

  /// Registering and unregistering run one at a time, in order.
  Future<void> _pushQueue = Future.value();

  Future<void> _serial(Future<void> Function() step) =>
      _pushQueue = _pushQueue.then((_) => step()).catchError((Object e) => debugPrint('push: $e'));

  /// Registers this phone for invite notifications, if they're on.
  Future<void> _registerPush() => _serial(() async {
    bool wanted() => ref.mounted && state.isReady && ref.read(settingsProvider).inviteNotifications;
    if (!wanted() || _api == null) return;
    if (!await _push.requestPermission() || !wanted()) return;
    final token = await _push.token();
    if (token == null || !wanted()) return;
    _pushToken = token;
    await _sendPushToken(token);
    if (!wanted()) return;
    _pushRefresh ??= _push.tokenRefresh.listen((t) {
      _pushToken = t;
      _sendPushToken(t);
    });
  });

  Future<void> _sendPushToken(String token) async {
    try {
      await _api?.registerPushToken(token);
    } on ApiException catch (e) {
      // An older server without the route, or offline: try again next time.
      debugPrint('push token not sent: ${e.code}');
    }
  }

  Future<void> _unregisterPush() => _serial(() async {
    await _pushRefresh?.cancel();
    _pushRefresh = null;
    final token = _pushToken ?? await _push.token();
    _pushToken = null;
    if (token != null) {
      try {
        await _api?.deletePushToken(token);
      } on ApiException catch (e) {
        debugPrint('push token not removed: ${e.code}');
      }
    }
    await _push.deleteToken();
  });

  /// The Settings switch for invite notifications.
  Future<void> setInviteNotifications(bool on) async {
    ref.read(settingsProvider.notifier).update((s) => s.copyWith(inviteNotifications: on));
    if (!state.isReady) return;
    on ? await _registerPush() : await _unregisterPush();
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

  /// Takes a profile the server sent with a reward (Forge Board claims).
  void applyProfile(ServerProfile server) {
    if (!state.isReady) return;
    ref.read(profileProvider.notifier).applyServer(server, pending: ref.read(storeProvider).loadSavedPuzzle());
    state = state.copyWith(server: server);
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
  /// Screens call this from dispose, which can outlive the controller.
  void setStatus(String status) {
    if (ref.mounted) _hub?.setStatus(status);
  }

  void invite(String friendId, String code, String mode) => _hub?.invite(friendId, code, mode);

  // ---- Rooms ----

  /// Creates a room and returns its code. Throws [ApiException].
  Future<String> createRoom(String mode) => _api!.createRoom(mode);

  /// Checks a typed code before joining. Throws [ApiException].
  /// The room's mode (`coop` or `vs`). Throws an [ApiException] if the room
  /// is missing, full or mid-round.
  Future<String> checkRoom(String code) async {
    final room = await _api!.room(code);
    final mode = room['mode'] as String? ?? 'coop';
    // Already holding a seat (dropped, or the app was closed): always allowed back.
    if (room['seated'] == true) return mode;
    final players = (room['players'] as num?)?.toInt() ?? 0;
    final max = (room['maxPlayers'] as num?)?.toInt() ?? 4;
    if (players >= max) throw const ApiException(409, 'room_full');
    if (const {'countdown', 'round', 'standings'}.contains(room['phase'])) {
      throw const ApiException(409, 'round_in_progress');
    }
    return mode;
  }

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
      case HubOpenRooms(:final rooms):
        state = state.copyWith(openRooms: rooms);
      case HubError(:final code):
        _hubErrors.add(code);
    }
  }

  final _hubErrors = StreamController<String>.broadcast();

  /// Hub error codes, e.g. `friend_offline` after an invite nobody can get.
  Stream<String> get hubErrors => _hubErrors.stream;

  // ---- Account deletion ----

  /// Deletes the account everywhere and resets this phone. Email accounts
  /// confirm their [password] first; Google accounts confirm with Google.
  Future<void> deleteAccount({String? password}) async {
    await _auth.reauthenticate(password: password);
    await _api!.deleteMe();
    await _stopHub();
    // The server dropped this phone's token with the account.
    await _pushRefresh?.cancel();
    _pushRefresh = null;
    _pushToken = null;
    await _push.deleteToken();
    await _auth.deleteUser();
    await ref.read(profileProvider.notifier).resetLocal();
    state = const AccountState(phase: AccountPhase.signedOut);
  }
}
