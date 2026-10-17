import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wordsmith/auth/auth_service.dart';
import 'package:wordsmith/net/api_client.dart';

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

  @override
  Future<void> reauthenticate(String password) async {
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
  Map<String, int> hints = {'hammer': 3, 'chisel': 0, 'sparks': 0};
  final synced = <Map<String, dynamic>>[];
  final takenNames = <String>{'taken'};
  final friends = <Map<String, Object>>[];
  final incoming = <Map<String, Object>>[];
  bool down = false;
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
      case 'GET /friends':
        return _json(200, {'friends': friends, 'incoming': incoming, 'outgoing': []});
      case 'POST /friends/request':
        return _json(200, {'status': 'pending'});
      case 'DELETE /me':
        deletedMe = true;
        return _json(200, {'ok': true});
    }
    return _json(404, {'error': 'not_found'});
  }

  static http.Response _json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
}
