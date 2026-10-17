import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wordsmith/auth/auth_service.dart';
import 'package:wordsmith/net/api_client.dart';
import 'package:wordsmith/game/daily_game.dart';
import 'package:wordsmith/net/push.dart';

/// Sign-in without Firebase.
class FakeAuth implements AuthService {
  FakeAuth({AuthUser? signedIn}) : _user = signedIn;

  AuthUser? _user;
  final _changes = StreamController<AuthUser?>.broadcast();
  final passwords = <String, String>{};
  bool deleted = false;

  @override
  AuthUser? get current => _user;

  /// Like Firebase: the current user first, then every change, with no gap
  /// in which a change could be missed.
  @override
  Stream<AuthUser?> get changes {
    late final StreamController<AuthUser?> out;
    out = StreamController<AuthUser?>(
      onListen: () {
        out.add(_user);
        final sub = _changes.stream.listen(out.add);
        out.onCancel = sub.cancel;
      },
    );
    return out.stream;
  }

  void _set(AuthUser? user) {
    _user = user;
    _changes.add(user);
  }

  @override
  Future<void> signIn(String email, String password) async {
    if (passwords[email] != password) {
      throw const AuthFailure('Wrong email or password.', code: 'invalid-credential');
    }
    _set(AuthUser(uid: 'uid-$email', email: email));
  }

  @override
  Future<void> signUp(String email, String password) async {
    passwords[email] = password;
    _set(AuthUser(uid: 'uid-$email', email: email));
  }

  @override
  Future<void> resetPassword(String email) async {}

  /// The Google account the picker returns; null means the player backs out.
  String? googleEmail;
  bool googleAvailableFlag = true;

  @override
  bool get googleAvailable => googleAvailableFlag;

  @override
  Future<bool> signInWithGoogle() async {
    final email = googleEmail;
    if (email == null) return false;
    _set(AuthUser(uid: 'uid-$email', email: email, usesPassword: false));
    return true;
  }

  @override
  Future<void> reauthenticate({String? password}) async {
    if (password == null) {
      if (googleEmail != _user?.email) {
        throw const AuthFailure('Confirm with Google to continue.', code: 'canceled');
      }
      return;
    }
    if (passwords[_user?.email] != password) {
      throw const AuthFailure('Wrong email or password.', code: 'invalid-credential');
    }
  }

  @override
  Future<void> signOut() async => _set(null);

  @override
  Future<void> deleteUser() async {
    deleted = true;
    _set(null);
  }

  @override
  Future<String?> idToken({bool refresh = false}) async => _user == null ? null : 'token-${_user!.uid}';
}

/// A tiny in-memory stand-in for the Worker's REST API (server/README.md).
class FakeServer {
  String? username;
  String avatar = 'avatar_01';
  int totalXp = 0;
  int completed = 0;
  int scrapBin = 0;
  int masterworkPieces = 0;
  Map<String, int> hints = {'hammer': 3, 'chisel': 0, 'sparks': 0};
  final synced = <Map<String, dynamic>>[];
  final takenNames = <String>{'taken'};
  final friends = <Map<String, Object>>[];
  final incoming = <Map<String, Object>>[];
  bool down = false;

  /// Room code → `GET /v1/rooms/:code` summary.
  final rooms = <String, Map<String, Object?>>{};

  /// The Daily Commission (shared/daily.md).
  Map<String, dynamic>? dailyPuzzle;
  bool dailyDone = false;
  int dailyStreak = 0;

  /// Earlier days done (calendar), and late days played.
  final dailyDays = <String>{};
  final dailyPosts = <Map<String, dynamic>>[];

  /// The Forge Board (shared/forge-board.md), kept simple.
  int stokeDay = 1;

  /// Claimed by default, so most tests don't get the Hall's Stoke prompt.
  bool stokeClaimed = true;
  final orders = <Map<String, Object?>>[
    {'slot': 'd0', 'kind': 'bonus_words', 'target': 10, 'progress': 10, 'claimed': false},
    {'slot': 'd1', 'kind': 'solo_puzzles', 'target': 3, 'progress': 1, 'claimed': false},
    {'slot': 'd2', 'kind': 'coop_rounds', 'target': 1, 'progress': 0, 'claimed': false, 'friends': true},
    {'slot': 'w0', 'kind': 'letter_hunt', 'target': 40, 'progress': 12, 'claimed': false, 'letter': 'R'},
    {'slot': 'w1', 'kind': 'solo_puzzles', 'target': 15, 'progress': 4, 'claimed': false},
  ];
  bool swapUsed = false;
  bool chestClaimed = false;
  final giftsPending = <Map<String, Object?>>[];
  final giftsSent = <String>{};
  int giftsClaimed = 0;
  Map<String, Object?>? lastWeek;
  bool lastWeekClaimed = false;

  static Map<String, Object> reward(int xp, [Map<String, int> hints = const {}]) => {
    'xp': xp,
    'hints': {'hammer': 0, 'chisel': 0, 'sparks': 0, ...hints},
  };

  Map<String, Object?> board(String uid) => {
    'date': todayUtc(),
    'week': '2026-W42',
    'stoke': {
      'day': stokeDay,
      'claimedToday': stokeClaimed,
      'track': [
        reward(15),
        reward(0, {'hammer': 1}),
        reward(25),
        reward(0, {'chisel': 1}),
        reward(35),
        reward(0, {'hammer': 2}),
        reward(50, {'sparks': 1}),
      ],
    },
    'orders': {
      'daily': [for (final o in orders.where((o) => (o['slot'] as String).startsWith('d'))) _order(o)],
      'weekly': [for (final o in orders.where((o) => (o['slot'] as String).startsWith('w'))) _order(o)],
      'chest': {
        'reward': reward(30, {'chisel': 1}),
        'ready': orders.where((o) => (o['slot'] as String).startsWith('d')).every((o) => o['claimed'] == true),
        'claimed': chestClaimed,
      },
      'swapAvailable': !swapUsed,
      'dailyEndsAt': DateTime.now().add(const Duration(hours: 5)).millisecondsSinceEpoch,
      'weeklyEndsAt': DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch,
    },
    'trials': {
      'week': '2026-W42',
      'endsAt': DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch,
      'standings': [
        {'id': uid, 'username': username ?? 'me', 'avatar': avatar, 'level': 1, 'xp': totalXp, 'me': true},
        for (final f in friends) {...f, 'xp': 40, 'me': false},
      ],
      'lastWeek': lastWeek == null ? null : {...lastWeek!, 'claimed': lastWeekClaimed},
    },
    'gifts': {
      'pending': giftsPending,
      'sentToday': giftsSent.toList(),
      'claimedToday': giftsClaimed,
      'claimLimit': 5,
    },
  };

  Map<String, Object?> _order(Map<String, Object?> o) => {
    'letter': null,
    'friends': false,
    ...o,
    'reward': (o['slot'] as String).startsWith('d') ? reward(20, {'hammer': 1}) : reward(100, {'sparks': 1}),
  };

  http.Response _claim(String uid, Map<String, Object> got) {
    totalXp += got['xp'] as int;
    for (final e in (got['hints'] as Map<String, int>).entries) {
      hints[e.key] = (hints[e.key] ?? 0) + e.value;
    }
    return _json(200, {'profile': profile(uid), 'board': board(uid), 'reward': got});
  }

  /// The daily reminder's UTC hour (shared/push.md), and how often it was set.
  int? reminderUtcHour;
  int reminderPuts = 0;

  /// Crucible runs received (shared/survival.md), and the best one.
  final survivalRuns = <Map<String, dynamic>>[];
  Map<String, Object>? survivalBest;

  /// Push tokens registered for invite notifications.
  final pushTokens = <String>{};
  bool deletedMe = false;
  final calls = <String>[];

  Map<String, Object?> profile(String uid) => {
    'id': uid,
    'username': username,
    'avatar': username == null ? null : avatar,
    'needsSetup': username == null,
    'totalXp': totalXp,
    'level': 1,
    'xpIntoLevel': totalXp,
    'xpForLevel': 60,
    'rank': 'Apprentice',
    'campaignCompleted': completed,
    'nextStage': completed + 1,
    'scrapBin': scrapBin,
    'hints': hints,
    'stats': {'wordsForged': synced.length * 3, 'longestWord': '', 'soloDone': synced.length},
    'masterworks': {'pieces': masterworkPieces},
    'survivalBest': survivalBest,
  };

  ApiClient client(AuthService auth) => ApiClient(
    baseUrl: 'https://forge.test',
    token: auth.idToken,
    client: MockClient(_handle),
  );

  Future<http.Response> _handle(http.Request req) async {
    if (down) throw http.ClientException('offline');
    final token = req.headers['Authorization']?.replaceFirst('Bearer token-', '');
    if (token == null) return _json(401, {'error': 'unauthorized'});
    final path = req.url.path.replaceFirst('/v1', '');
    calls.add('${req.method} $path');
    final body = req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;
    switch ('${req.method} $path') {
      case 'GET /me':
        return _json(200, profile(token));
      case 'POST /me/setup':
        final name = body['username'] as String;
        if (takenNames.contains(name.toLowerCase())) {
          return _json(409, {'error': 'username_taken'});
        }
        username = name;
        avatar = body['avatar'] as String;
        return _json(200, profile(token));
      case 'POST /solo/sync':
        final entries = (body['entries'] as List).cast<Map<String, dynamic>>();
        for (final e in entries) {
          synced.add(e);
          totalXp += 10;
          final stage = e['stage'] as int;
          if (stage > completed) completed = stage;
          final used = (e['hintsUsed'] as Map).cast<String, int>();
          for (final u in used.entries) {
            hints[u.key] = (hints[u.key]! - u.value).clamp(0, 999);
          }
        }
        return _json(200, {
          'profile': profile(token),
          'results': [
            for (final e in entries) {'stage': e['stage'], 'accepted': true},
          ],
        });
      case 'POST /survival/solo':
        if (survivalRuns.any((r) => r['runId'] == body['runId'])) {
          return _json(200, {'profile': profile(token), 'xp': {'xp': 0, 'level': 1, 'levelUps': 0}, 'duplicate': true});
        }
        survivalRuns.add(body);
        final puzzles = (body['puzzles'] as List).cast<Map<String, dynamic>>();
        final words = puzzles.fold<int>(0, (n, p) => n + (p['foundWords'] as List).length);
        final cleared = puzzles.where((p) => p['cleared'] == true).length;
        final xp = (words + 8 * cleared).clamp(0, 150);
        totalXp += xp;
        for (final p in puzzles) {
          for (final u in (p['hintsUsed'] as Map).cast<String, int>().entries) {
            hints[u.key] = ((hints[u.key] ?? 0) - u.value).clamp(0, 999);
          }
        }
        final best = {'puzzles': cleared, 'words': words, 'saved': body['saved'] as int, 'at': 1};
        final newBest = survivalBest == null || cleared > (survivalBest!['puzzles'] as int);
        if (newBest) survivalBest = best;
        return _json(200, {
          'profile': profile(token),
          'xp': {'xp': xp, 'level': 1, 'levelUps': 0, 'rewards': {}},
          'best': survivalBest,
          'newBest': newBest,
        });
      case 'GET /friends':
        return _json(200, {'friends': friends, 'incoming': incoming, 'outgoing': []});
      case 'POST /friends/request':
        return _json(200, {'status': 'pending'});
      case 'DELETE /me':
        deletedMe = true;
        return _json(200, {'ok': true});
      case 'POST /me/push-token':
        pushTokens.add(body['token'] as String);
        return _json(200, {'ok': true});
      case 'DELETE /me/push-token':
        pushTokens.remove(body['token']);
        return _json(200, {'ok': true});
      case 'GET /daily':
        if (dailyPuzzle == null) return _json(404, {'error': 'not_found'});
        final date = req.url.queryParameters['date'] ?? todayUtc();
        return _json(200, {
          'date': date,
          'heat': 1,
          'puzzle': dailyPuzzle,
          'completed': date == todayUtc() ? dailyDone : dailyDays.contains(date),
          'streak': dailyStreak,
          'best': dailyStreak > 3 ? dailyStreak : 3,
          'total': dailyDays.length + (dailyDone ? 1 : 0),
        });
      case 'GET /daily/calendar':
        final month = req.url.queryParameters['month']!;
        final days = {...dailyDays, if (dailyDone) todayUtc()}.where((d) => d.startsWith(month)).toList()..sort();
        return _json(200, {
          'month': month,
          'days': days,
          'trophy': days.length >= 7 ? 'bronze' : null,
          'trophies': {'bronze': 1, 'silver': 0, 'gold': 2},
        });
      case 'PUT /me/reminder':
        reminderUtcHour = body['hour'] as int?;
        reminderPuts++;
        return _json(200, {'ok': true, 'hour': reminderUtcHour});
      case 'GET /me/board':
        return _json(200, board(token));
      case 'POST /me/stoke/claim':
        if (stokeClaimed) return _json(409, {'error': 'already_claimed'});
        stokeClaimed = true;
        return _claim(token, reward(15));
      case 'POST /me/orders/claim':
        final slot = body['slot'] as String;
        if (slot == 'chest') {
          chestClaimed = true;
          return _claim(token, reward(30, {'chisel': 1}));
        }
        final o = orders.firstWhere((o) => o['slot'] == slot);
        if ((o['progress'] as int) < (o['target'] as int)) return _json(409, {'error': 'not_done'});
        if (o['claimed'] == true) return _json(409, {'error': 'already_claimed'});
        o['claimed'] = true;
        return _claim(token, reward(20, {'hammer': 1}));
      case 'POST /me/orders/swap':
        if (swapUsed) return _json(409, {'error': 'swap_used'});
        swapUsed = true;
        final o = orders.firstWhere((o) => o['slot'] == body['slot']);
        o
          ..['kind'] = 'long_words'
          ..['target'] = 3
          ..['progress'] = 0
          ..['friends'] = false;
        return _claim(token, reward(0));
      case 'POST /me/trials/claim':
        if (lastWeek == null || lastWeekClaimed) return _json(409, {'error': 'no_prize'});
        lastWeekClaimed = true;
        return _claim(token, reward(100, {'sparks': 1}));
      case 'POST /me/gifts/claim':
        if (giftsPending.isEmpty) return _json(409, {'error': 'nothing_to_claim'});
        final n = giftsPending.length;
        giftsPending.clear();
        giftsClaimed += n;
        return _claim(token, reward(0, {'hammer': n}));
      case 'POST /daily/complete':
        dailyPosts.add(body);
        if (body['date'] != todayUtc()) {
          final first = dailyDays.add(body['date'] as String);
          if (first) totalXp += 15;
          return _json(200, {
            'profile': profile(token),
            'xp': first ? 15 : 0,
            'streak': dailyStreak,
            'best': dailyStreak > 3 ? dailyStreak : 3,
            'alreadyDone': !first,
          });
        }
        final already = dailyDone;
        if (!already) {
          dailyDone = true;
          dailyStreak++;
          totalXp += 25;
        }
        return _json(200, {
          'profile': profile(token),
          'xp': already ? 0 : 25,
          'streak': dailyStreak,
          'best': dailyStreak > 3 ? dailyStreak : 3,
          'alreadyDone': already,
        });
    }
    final gift = RegExp(r'^/friends/([^/]+)/gift$').firstMatch(path);
    if (req.method == 'POST' && gift != null) {
      if (!giftsSent.add(gift.group(1)!)) return _json(409, {'error': 'already_sent'});
      return _json(200, {'ok': true});
    }
    if (req.method == 'GET' && path.startsWith('/rooms/')) {
      final room = rooms[path.substring('/rooms/'.length)];
      return room == null ? _json(404, {'error': 'room_not_found'}) : _json(200, room);
    }
    return _json(404, {'error': 'not_found'});
  }

  static http.Response _json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
}

/// Invite notifications without Firebase.
class FakePush implements PushService {
  bool allowed = true;
  String? current = 'fcm-token-1';
  int deletes = 0;
  final _refresh = StreamController<String>.broadcast();
  final _opened = StreamController<Map<String, dynamic>>.broadcast();

  void refresh(String token) {
    current = token;
    _refresh.add(token);
  }

  void tap(Map<String, dynamic> data) => _opened.add(data);

  @override
  Future<bool> requestPermission() async => allowed;
  @override
  Future<String?> token() async => current;
  @override
  Stream<String> get tokenRefresh => _refresh.stream;
  @override
  Stream<Map<String, dynamic>> get opened => _opened.stream;
  @override
  Future<Map<String, dynamic>?> initialOpen() async => null;
  @override
  Future<void> deleteToken() async {
    deletes++;
    current = 'fcm-token-${deletes + 1}';
  }
}
