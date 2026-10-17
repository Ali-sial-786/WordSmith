/// Server JSON shapes (server/README.md).
library;

import '../engine/hints.dart';

class ServerStats {
  const ServerStats({
    this.wordsForged = 0,
    this.longestWord = '',
    this.soloDone = 0,
    this.coopRounds = 0,
    this.coopMvps = 0,
    this.vsSeries = 0,
    this.vsSeriesWon = 0,
    this.vsRoundsWon = 0,
  });

  factory ServerStats.fromJson(Map<String, dynamic> j) => ServerStats(
    wordsForged: j['wordsForged'] as int? ?? 0,
    longestWord: j['longestWord'] as String? ?? '',
    soloDone: j['soloDone'] as int? ?? 0,
    coopRounds: j['coopRounds'] as int? ?? 0,
    coopMvps: j['coopMvps'] as int? ?? 0,
    vsSeries: j['vsSeries'] as int? ?? 0,
    vsSeriesWon: j['vsSeriesWon'] as int? ?? 0,
    vsRoundsWon: j['vsRoundsWon'] as int? ?? 0,
  );

  final int wordsForged;
  final String longestWord;
  final int soloDone;
  final int coopRounds;
  final int coopMvps;
  final int vsSeries;
  final int vsSeriesWon;
  final int vsRoundsWon;
}

class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.username,
    required this.avatar,
    required this.needsSetup,
    required this.totalXp,
    required this.level,
    required this.rank,
    required this.nextStage,
    required this.scrapBin,
    required this.hints,
    required this.stats,
  });

  factory ServerProfile.fromJson(Map<String, dynamic> j) => ServerProfile(
    id: j['id'] as String,
    username: j['username'] as String?,
    avatar: j['avatar'] as String?,
    needsSetup: j['needsSetup'] as bool? ?? false,
    totalXp: j['totalXp'] as int? ?? 0,
    level: j['level'] as int? ?? 1,
    rank: j['rank'] as String? ?? '',
    nextStage: j['nextStage'] as int? ?? 1,
    scrapBin: j['scrapBin'] as int? ?? 0,
    hints: {
      for (final e in ((j['hints'] as Map?) ?? const {}).entries)
        HintKind.byName(e.key as String): (e.value as num).toInt(),
    },
    stats: ServerStats.fromJson((j['stats'] as Map?)?.cast() ?? const {}),
  );

  final String id;
  final String? username;
  final String? avatar;
  final bool needsSetup;
  final int totalXp;
  final int level;
  final String rank;
  final int nextStage;
  final int scrapBin;
  final Map<HintKind, int> hints;
  final ServerStats stats;
}

class PlayerSummary {
  const PlayerSummary({
    required this.id,
    required this.username,
    required this.avatar,
    required this.level,
    required this.rank,
  });

  factory PlayerSummary.fromJson(Map<String, dynamic> j) => PlayerSummary(
    id: j['id'] as String,
    username: j['username'] as String? ?? '?',
    avatar: j['avatar'] as String? ?? 'avatar_01',
    level: j['level'] as int? ?? 1,
    rank: j['rank'] as String? ?? '',
  );

  final String id;
  final String username;
  final String avatar;
  final int level;
  final String rank;
}

class FriendsList {
  const FriendsList({
    this.friends = const [],
    this.incoming = const [],
    this.outgoing = const [],
  });

  factory FriendsList.fromJson(Map<String, dynamic> j) {
    List<PlayerSummary> list(String key) => [
      for (final f in ((j[key] as List?) ?? const []).cast<Map<String, dynamic>>())
        PlayerSummary.fromJson(f),
    ];
    return FriendsList(
      friends: list('friends'),
      incoming: list('incoming'),
      outgoing: list('outgoing'),
    );
  }

  final List<PlayerSummary> friends;
  final List<PlayerSummary> incoming;
  final List<PlayerSummary> outgoing;
}

class LeaderboardEntry {
  const LeaderboardEntry({
    required this.place,
    required this.player,
    required this.totalXp,
    required this.vsSeriesWon,
    required this.me,
  });

  factory LeaderboardEntry.fromJson(Map<String, dynamic> j) => LeaderboardEntry(
    place: j['place'] as int? ?? 0,
    player: PlayerSummary.fromJson(j),
    totalXp: j['totalXp'] as int? ?? 0,
    vsSeriesWon: j['vsSeriesWon'] as int? ?? 0,
    me: j['me'] as bool? ?? false,
  );

  final int place;
  final PlayerSummary player;
  final int totalXp;
  final int vsSeriesWon;
  final bool me;
}

class SyncOutcome {
  const SyncOutcome({required this.profile, required this.accepted, required this.rejected});

  factory SyncOutcome.fromJson(Map<String, dynamic> j) {
    final results = ((j['results'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return SyncOutcome(
      profile: ServerProfile.fromJson(j['profile'] as Map<String, dynamic>),
      accepted: results.where((r) => r['accepted'] == true).length,
      rejected: [
        for (final r in results)
          if (r['accepted'] != true) '${r['stage']}: ${r['reason']}',
      ],
    );
  }

  final ServerProfile profile;
  final int accepted;

  /// "stage: reason" for entries the server turned down.
  final List<String> rejected;
}
