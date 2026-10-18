/// Server JSON shapes (server/README.md).
library;

import '../engine/hints.dart';
import '../engine/puzzle.dart';

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
    this.masterworkPieces = 0,
    this.survivalBest,
    this.nextUsernameChangeAt,
  });

  factory ServerProfile.fromJson(Map<String, dynamic> j) => ServerProfile(
    id: j['id'] as String,
    username: j['username'] as String?,
    avatar: j['avatar'] as String?,
    needsSetup: j['needsSetup'] as bool? ?? false,
    nextUsernameChangeAt: switch (j['nextUsernameChangeAt']) {
      final num at => DateTime.fromMillisecondsSinceEpoch(at.toInt()),
      _ => null,
    },
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
    masterworkPieces: ((j['masterworks'] as Map?)?['pieces'] as num?)?.toInt() ?? 0,
    survivalBest: j['survivalBest'] is Map ? SurvivalBest.fromJson((j['survivalBest'] as Map).cast()) : null,
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
  final int masterworkPieces;

  /// The best Crucible run (shared/survival.md).
  final SurvivalBest? survivalBest;

  /// When the username may next change (once a week); null or past means now.
  final DateTime? nextUsernameChangeAt;

  /// Whether `POST /v1/me/username` would be turned away as too soon.
  bool get usernameLocked => nextUsernameChangeAt?.isAfter(DateTime.now()) ?? false;
}

/// A Crucible run's score: puzzles cleared, then words, then saved.
class SurvivalBest {
  const SurvivalBest({required this.puzzles, required this.words, required this.saved, this.at = 0});

  factory SurvivalBest.fromJson(Map<String, dynamic> j) => SurvivalBest(
    puzzles: (j['puzzles'] as num?)?.toInt() ?? 0,
    words: (j['words'] as num?)?.toInt() ?? 0,
    saved: (j['saved'] as num?)?.toInt() ?? 0,
    at: (j['at'] as num?)?.toInt() ?? 0,
  );

  final int puzzles;
  final int words;
  final int saved;
  final int at;

  Map<String, Object> toJson() => {'puzzles': puzzles, 'words': words, 'saved': saved, 'at': at};

  /// Whether this run beats [other].
  bool beats(SurvivalBest? other) {
    if (other == null) return puzzles + words + saved > 0;
    if (puzzles != other.puzzles) return puzzles > other.puzzles;
    if (words != other.words) return words > other.words;
    return saved > other.saved;
  }
}

/// What `POST /v1/survival/solo` gave for a run.
class SurvivalOutcome {
  const SurvivalOutcome({
    required this.profile,
    required this.xp,
    required this.level,
    required this.levelUps,
    required this.best,
    required this.newBest,
  });

  factory SurvivalOutcome.fromJson(Map<String, dynamic> j) {
    final xp = (j['xp'] as Map?)?.cast<String, dynamic>() ?? const {};
    return SurvivalOutcome(
      profile: ServerProfile.fromJson(j['profile'] as Map<String, dynamic>),
      xp: (xp['xp'] as num?)?.toInt() ?? 0,
      level: (xp['level'] as num?)?.toInt() ?? 1,
      levelUps: (xp['levelUps'] as num?)?.toInt() ?? 0,
      best: j['best'] is Map ? SurvivalBest.fromJson((j['best'] as Map).cast()) : null,
      newBest: j['newBest'] as bool? ?? false,
    );
  }

  final ServerProfile profile;
  final int xp;
  final int level;
  final int levelUps;
  final SurvivalBest? best;
  final bool newBest;
}

class PlayerSummary {
  const PlayerSummary({
    required this.id,
    required this.username,
    required this.avatar,
    required this.level,
    required this.rank,
    this.nickname,
  });

  factory PlayerSummary.fromJson(Map<String, dynamic> j) => PlayerSummary(
    id: j['id'] as String,
    username: j['username'] as String? ?? '?',
    avatar: j['avatar'] as String? ?? 'avatar_01',
    level: j['level'] as int? ?? 1,
    rank: j['rank'] as String? ?? '',
    nickname: j['nickname'] as String?,
  );

  final String id;
  final String username;
  final String avatar;
  final int level;
  final String rank;

  /// My private name for this friend (friends list only), shown instead of [username].
  final String? nickname;

  PlayerSummary withNickname(String? nickname) =>
      PlayerSummary(id: id, username: username, avatar: avatar, level: level, rank: rank, nickname: nickname);
}

class FriendsList {
  const FriendsList({this.friends = const [], this.incoming = const [], this.outgoing = const []});

  factory FriendsList.fromJson(Map<String, dynamic> j) {
    List<PlayerSummary> list(String key) => [
      for (final f in ((j[key] as List?) ?? const []).cast<Map<String, dynamic>>()) PlayerSummary.fromJson(f),
    ];
    return FriendsList(friends: list('friends'), incoming: list('incoming'), outgoing: list('outgoing'));
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

/// Today's Daily Commission (shared/daily.md).
class DailyInfo {
  const DailyInfo({
    required this.date,
    required this.heat,
    required this.puzzle,
    required this.completed,
    required this.streak,
    required this.best,
    this.total = 0,
  });

  factory DailyInfo.fromJson(Map<String, dynamic> j) => DailyInfo(
    date: j['date'] as String,
    heat: (j['heat'] as num?)?.toInt() ?? 1,
    puzzle: Puzzle.fromJson(j['puzzle'] as Map<String, dynamic>),
    completed: j['completed'] as bool? ?? false,
    streak: (j['streak'] as num?)?.toInt() ?? 0,
    best: (j['best'] as num?)?.toInt() ?? 0,
    total: (j['total'] as num?)?.toInt() ?? 0,
  );

  /// The UTC day, `YYYY-MM-DD`.
  final String date;
  final int heat;
  final Puzzle puzzle;
  final bool completed;
  final int streak;
  final int best;

  /// Every commission I've completed, late ones included (Lore Book pages).
  final int total;
}

/// One month of the Daily Commission calendar.
class DailyCalendar {
  const DailyCalendar({required this.month, required this.days, required this.trophy, required this.trophies});

  factory DailyCalendar.fromJson(Map<String, dynamic> j) {
    final t = (j['trophies'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DailyCalendar(
      month: j['month'] as String? ?? '',
      days: {...((j['days'] as List?) ?? const []).cast<String>()},
      trophy: j['trophy'] as String?,
      trophies: (
        bronze: (t['bronze'] as num?)?.toInt() ?? 0,
        silver: (t['silver'] as num?)?.toInt() ?? 0,
        gold: (t['gold'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  /// `YYYY-MM`.
  final String month;

  /// Dates done that month, `YYYY-MM-DD`.
  final Set<String> days;

  /// "bronze", "silver", "gold" or null.
  final String? trophy;
  final ({int bronze, int silver, int gold}) trophies;
}

class DailyOutcome {
  const DailyOutcome({
    required this.profile,
    required this.xp,
    required this.streak,
    required this.best,
    required this.alreadyDone,
  });

  factory DailyOutcome.fromJson(Map<String, dynamic> j) => DailyOutcome(
    profile: ServerProfile.fromJson(j['profile'] as Map<String, dynamic>),
    xp: (j['xp'] as num?)?.toInt() ?? 0,
    streak: (j['streak'] as num?)?.toInt() ?? 0,
    best: (j['best'] as num?)?.toInt() ?? 0,
    alreadyDone: j['alreadyDone'] as bool? ?? false,
  );

  final ServerProfile profile;
  final int xp;
  final int streak;
  final int best;
  final bool alreadyDone;
}
