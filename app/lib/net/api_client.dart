import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/lexicon.dart' show Meaning, Sense;
import 'board.dart';
import 'models.dart';

/// An error response from the server, or no response at all.
class ApiException implements Exception {
  const ApiException(this.status, this.code, [this.message, this.data = const {}]);

  /// 0 when the server couldn't be reached.
  final int status;
  final String code;
  final String? message;

  /// The whole error body, for codes that carry more.
  final Map<String, dynamic> data;

  bool get offline => status == 0;

  /// Words for players.
  String get friendly => switch (code) {
    'offline' => "Can't reach the forge. Check your connection.",
    'username_taken' => 'That name is taken. Try another.',
    'invalid_username' => 'Use 3–16 letters, numbers or _.',
    'username_not_allowed' => "That name isn't allowed. Try another.",
    'invalid_nickname' => 'Nicknames are 1–20 characters, on one line.',
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
    'wrong_day' => "That day's commission can't be forged any more. Today's is waiting!",
    'wrong_month' => 'The calendar only goes back to last month.',
    'already_claimed' => 'Already claimed.',
    'not_done' => "That order isn't finished yet.",
    'swap_used' => "You've already swapped an order today.",
    'order_done' => "A finished order can't be swapped.",
    'no_prize' => 'No prize from last week.',
    'nothing_to_claim' => 'No gifts to collect right now.',
    'already_sent' => 'You already sent them a gift today.',
    'not_friends' => "That smith isn't on your friends list any more.",
    'invalid_run' => "The forge couldn't count that run.",
    'under_13' => 'Online play is for players 13 and over. Solo play is all yours.',
    'quebec_not_offered' => "Online play isn't offered in Quebec. Solo play is all yours.",
    'invalid_birth' => 'Choose the month and year you were born.',
    'age_already_set' => 'Your age is already set. Write to us through Contact us if it needs fixing.',
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
  ApiClient({required this.baseUrl, required this.token, this.notInQuebec, http.Client? client})
    : _http = client ?? http.Client();

  final String baseUrl;
  final Future<String?> Function() token;

  /// Whether the player has said they don't live in Quebec: every call then
  /// says so, for when their connection places them there (shared/region.md).
  final bool Function()? notInQuebec;
  final http.Client _http;

  static const _timeout = Duration(seconds: 15);

  Future<Map<String, dynamic>> _send(String method, String path, {Object? body, bool auth = true}) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (notInQuebec?.call() ?? false) headers['X-Not-In-Quebec'] = '1';
    if (auth) {
      String? t;
      try {
        t = await token();
      } on Exception {
        // Refreshing an expired ID token needs the network.
        throw const ApiException(0, 'offline');
      }
      if (t == null) throw const ApiException(401, 'unauthorized', 'not_signed_in');
      headers['Authorization'] = 'Bearer $t';
    }
    final request = http.Request(method, Uri.parse('$baseUrl/v1$path'))..headers.addAll(headers);
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
        json,
      );
    }
    return json;
  }

  Future<Map<String, dynamic>> version() => _send('GET', '/version', auth: false);

  /// What [word] means, from an online dictionary (the Free Dictionary API,
  /// then Wiktionary), for words the offline lexicon lacks. Needs no
  /// sign-in, like [version]. Null when neither dictionary has the word.
  Future<Meaning?> define(String word) async {
    final Map<String, dynamic> j;
    try {
      j = await _send('GET', '/define/${Uri.encodeComponent(word.toLowerCase())}', auth: false);
    } on ApiException catch (e) {
      if (e.code == 'word_not_found') return null;
      rethrow;
    }
    final senses = [
      for (final s in (j['senses'] as List).cast<Map<String, dynamic>>())
        Sense(s['pos'] as String? ?? '', s['gloss'] as String),
    ];
    if (senses.isEmpty) return null;
    return Meaning(
      word: word.toUpperCase(),
      senses: senses,
      source: j['source'] as String?,
      sourceUrl: j['sourceUrl'] as String?,
      license: j['license'] as String?,
      licenseUrl: j['licenseUrl'] as String?,
    );
  }

  Future<ServerProfile> me() async => ServerProfile.fromJson(await _send('GET', '/me'));

  /// The username and avatar, and at first setup the birth month and year
  /// (shared/age.md): `403 under_13` deletes the account.
  Future<ServerProfile> setup(String username, String avatar, {int? birthYear, int? birthMonth}) async =>
      ServerProfile.fromJson(
        await _send(
          'POST',
          '/me/setup',
          body: {'username': username, 'avatar': avatar, 'birthYear': ?birthYear, 'birthMonth': ?birthMonth},
        ),
      );

  /// The birth month and year of an account made before ages were asked.
  Future<ServerProfile> confirmAge(int birthYear, int birthMonth) async =>
      ServerProfile.fromJson(await _send('POST', '/me/age', body: {'birthYear': birthYear, 'birthMonth': birthMonth}));

  /// A new username, as often as the player likes.
  Future<ServerProfile> changeUsername(String username) async =>
      ServerProfile.fromJson(await _send('POST', '/me/username', body: {'username': username}));

  Future<void> deleteMe() => _send('DELETE', '/me');

  Future<SyncOutcome> soloSync(List<Map<String, dynamic>> entries) async =>
      SyncOutcome.fromJson(await _send('POST', '/solo/sync', body: {'entries': entries}));

  /// A finished Crucible run (shared/survival.md).
  Future<SurvivalOutcome> survivalSolo(Map<String, dynamic> run) async =>
      SurvivalOutcome.fromJson(await _send('POST', '/survival/solo', body: run));

  Future<FriendsList> friends() async => FriendsList.fromJson(await _send('GET', '/friends'));

  /// Returns "pending" or "accepted".
  Future<String> requestFriend(String username) async =>
      (await _send('POST', '/friends/request', body: {'username': username}))['status'] as String;

  Future<void> respondFriend(String userId, {required bool accept}) =>
      _send('POST', '/friends/respond', body: {'userId': userId, 'accept': accept});

  Future<void> removeFriend(String userId) => _send('DELETE', '/friends/${Uri.encodeComponent(userId)}');

  // ---- Blocks and reports (shared/safety.md) ----

  Future<List<BlockedPlayer>> blocks() async => [
    for (final b in ((await _send('GET', '/me/blocks'))['blocks'] as List? ?? const []).cast<Map<String, dynamic>>())
      BlockedPlayer.fromJson(b),
  ];

  Future<void> block(String userId) => _send('PUT', '/me/blocks/${Uri.encodeComponent(userId)}', body: const {});
  Future<void> unblock(String userId) => _send('DELETE', '/me/blocks/${Uri.encodeComponent(userId)}');

  /// [lines] are the reported player's chat lines as I saw them: `{id, text, at}`.
  Future<void> report({
    required String userId,
    required ReportReason reason,
    String? details,
    String? room,
    List<Map<String, Object>> lines = const [],
  }) => _send(
    'POST',
    '/reports',
    body: {
      'userId': userId,
      'reason': reason.name,
      if (details != null && details.trim().isNotEmpty) 'details': details.trim(),
      'room': ?room,
      if (lines.isNotEmpty) 'lines': lines,
    },
  );

  /// My private nickname for a friend, or null to clear it. Returns it as stored (trimmed).
  Future<String?> setNickname(String friendId, String? nickname) async =>
      (await _send(
            'PUT',
            '/friends/${Uri.encodeComponent(friendId)}/nickname',
            body: {'nickname': nickname},
          ))['nickname']
          as String?;

  /// Creates a room and returns its code.
  Future<String> createRoom(String mode) async =>
      (await _send('POST', '/rooms', body: {'mode': mode}))['code'] as String;

  /// Room summary; throws `room_not_found` for a bad code.
  Future<Map<String, dynamic>> room(String code) => _send('GET', '/rooms/${Uri.encodeComponent(code)}');

  /// Today's Daily Commission, or an earlier [date] (`YYYY-MM-DD`) to play late.
  Future<DailyInfo> daily({String? date}) async =>
      DailyInfo.fromJson(await _send('GET', date == null ? '/daily' : '/daily?date=$date'));

  /// The days I've done in [month] (`YYYY-MM`) and my trophies.
  Future<DailyCalendar> dailyCalendar(String month) async =>
      DailyCalendar.fromJson(await _send('GET', '/daily/calendar?month=$month'));

  // ---- The Forge Board (shared/forge-board.md) ----

  Future<ForgeBoard> board() async => ForgeBoard.fromJson(await _send('GET', '/me/board'));

  Future<BoardClaim> claimStoke() async => BoardClaim.fromJson(await _send('POST', '/me/stoke/claim', body: const {}));

  /// [slot] is `d0`–`d2`, `w0`, `w1` or `chest`.
  Future<BoardClaim> claimOrder(String slot) async =>
      BoardClaim.fromJson(await _send('POST', '/me/orders/claim', body: {'slot': slot}));

  Future<BoardClaim> swapOrder(String slot) async =>
      BoardClaim.fromJson(await _send('POST', '/me/orders/swap', body: {'slot': slot}));

  Future<BoardClaim> claimTrials() async =>
      BoardClaim.fromJson(await _send('POST', '/me/trials/claim', body: const {}));

  Future<BoardClaim> claimGifts() async => BoardClaim.fromJson(await _send('POST', '/me/gifts/claim', body: const {}));

  /// The Daily Commission reminder's UTC hour, or null for none (shared/push.md).
  Future<void> setReminder(int? utcHour) => _send('PUT', '/me/reminder', body: {'hour': utcHour});

  Future<void> sendGift(String friendId) =>
      _send('POST', '/friends/${Uri.encodeComponent(friendId)}/gift', body: const {});

  /// Invite notifications to this phone (shared/push.md).
  Future<void> registerPushToken(String token) => _send('POST', '/me/push-token', body: {'token': token});
  Future<void> deletePushToken(String token) => _send('DELETE', '/me/push-token', body: {'token': token});

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
    for (final e in ((await _send('GET', '/leaderboard'))['entries'] as List).cast<Map<String, dynamic>>())
      LeaderboardEntry.fromJson(e),
  ];
}
