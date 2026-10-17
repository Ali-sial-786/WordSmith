import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// An error response from the server, or no response at all.
class ApiException implements Exception {
  const ApiException(this.status, this.code, [this.message]);

  /// 0 when the server couldn't be reached.
  final int status;
  final String code;
  final String? message;

  bool get offline => status == 0;

  /// Words for players.
  String get friendly => switch (code) {
    'offline' => "Can't reach the forge. Check your connection.",
    'username_taken' => 'That name is taken. Try another.',
    'invalid_username' => 'Use 3–16 letters, numbers or _.',
    'username_not_allowed' => "That name isn't allowed. Try another.",
    'user_not_found' => 'No smith by that name.',
    'cannot_friend_self' => "That's you!",
    'already_friends' => "You're already friends.",
    'too_many_requests' => 'Too many friend requests waiting. Try later.',
    'setup_required' => 'Pick a name first.',
    'room_not_found' => 'No forge with that code. Check it and try again.',
    'room_full' => 'That forge is full.',
    'round_in_progress' => "They're mid-round. Try again when it ends.",
    'video_unavailable' => "Video chat isn't set up on the server yet.",
    'not_in_room' => 'Join the room first.',
    'wrong_day' => "That was yesterday's commission. Today's is waiting!",
    // An unknown route: the server is older than this app.
    'not_found' => "The forge server doesn't have that yet. Try again after it's updated.",
    _ => message ?? 'Something went wrong ($code).',
  };

  @override
  String toString() => 'ApiException($status, $code, $message)';
}

/// REST client for the Worker (server/README.md). [token] supplies a fresh
/// Firebase ID token for each call.
class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.token,
    http.Client? client,
  }) : _http = client ?? http.Client();

  final String baseUrl;
  final Future<String?> Function() token;
  final http.Client _http;

  static const _timeout = Duration(seconds: 15);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Object? body,
    bool auth = true,
  }) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (auth) {
      final t = await token();
      if (t == null) throw const ApiException(401, 'unauthorized', 'not_signed_in');
      headers['Authorization'] = 'Bearer $t';
    }
    final request = http.Request(method, Uri.parse('$baseUrl/v1$path'))
      ..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(request).timeout(_timeout));
    } on TimeoutException {
      throw const ApiException(0, 'offline');
    } on http.ClientException {
      throw const ApiException(0, 'offline');
    } on Exception {
      throw const ApiException(0, 'offline');
    }
    Map<String, dynamic> json;
    try {
      json = res.body.isEmpty ? {} : jsonDecode(res.body) as Map<String, dynamic>;
    } on FormatException {
      throw ApiException(res.statusCode, 'bad_response');
    }
    if (res.statusCode >= 400) {
      throw ApiException(
        res.statusCode,
        json['error'] as String? ?? 'http_${res.statusCode}',
        json['message'] as String?,
      );
    }
    return json;
  }

  Future<Map<String, dynamic>> version() => _send('GET', '/version', auth: false);

  Future<ServerProfile> me() async => ServerProfile.fromJson(await _send('GET', '/me'));

  Future<ServerProfile> setup(String username, String avatar) async => ServerProfile.fromJson(
    await _send('POST', '/me/setup', body: {'username': username, 'avatar': avatar}),
  );

  Future<void> deleteMe() => _send('DELETE', '/me');

  Future<SyncOutcome> soloSync(List<Map<String, dynamic>> entries) async =>
      SyncOutcome.fromJson(await _send('POST', '/solo/sync', body: {'entries': entries}));

  Future<FriendsList> friends() async => FriendsList.fromJson(await _send('GET', '/friends'));

  /// Returns "pending" or "accepted".
  Future<String> requestFriend(String username) async =>
      (await _send('POST', '/friends/request', body: {'username': username}))['status']
          as String;

  Future<void> respondFriend(String userId, {required bool accept}) =>
      _send('POST', '/friends/respond', body: {'userId': userId, 'accept': accept});

  Future<void> removeFriend(String userId) =>
      _send('DELETE', '/friends/${Uri.encodeComponent(userId)}');

  /// Creates a room and returns its code.
  Future<String> createRoom(String mode) async =>
      (await _send('POST', '/rooms', body: {'mode': mode}))['code'] as String;

  /// Room summary; throws `room_not_found` for a bad code.
  Future<Map<String, dynamic>> room(String code) =>
      _send('GET', '/rooms/${Uri.encodeComponent(code)}');

  Future<DailyInfo> daily() async => DailyInfo.fromJson(await _send('GET', '/daily'));

  Future<DailyOutcome> completeDaily({
    required String date,
    required List<String> foundWords,
    required List<String> bonusWords,
    required Map<String, int> hintsUsed,
    required int durationMs,
  }) async => DailyOutcome.fromJson(
    await _send(
      'POST',
      '/daily/complete',
      body: {
        'date': date,
        'foundWords': foundWords,
        'bonusWords': bonusWords,
        'hintsUsed': hintsUsed,
        'durationMs': durationMs,
      },
    ),
  );

  /// A LiveKit token for a room's video chat; only for players in the room.
  Future<({String url, String token})> roomVideo(String code) async {
    final j = await _send('POST', '/rooms/${Uri.encodeComponent(code)}/video', body: const {});
    return (url: j['url'] as String, token: j['token'] as String);
  }

  Future<List<LeaderboardEntry>> leaderboard() async => [
    for (final e in ((await _send('GET', '/leaderboard'))['entries'] as List)
        .cast<Map<String, dynamic>>())
      LeaderboardEntry.fromJson(e),
  ];
}
