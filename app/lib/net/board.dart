/// The Forge Board: Daily Stoke, Work Orders, Weekly Trials and Gifts
/// (shared/forge-board.md).
library;

import '../engine/hints.dart';
import 'models.dart';

/// XP and hints granted together.
class Reward {
  const Reward({this.xp = 0, this.hints = const {}});

  factory Reward.fromJson(Map<String, dynamic>? j) => Reward(
    xp: (j?['xp'] as num?)?.toInt() ?? 0,
    hints: {
      for (final e in ((j?['hints'] as Map?) ?? const {}).entries)
        if ((e.value as num) > 0) HintKind.byName(e.key as String): (e.value as num).toInt(),
    },
  );

  final int xp;
  final Map<HintKind, int> hints;

  bool get isEmpty => xp == 0 && hints.isEmpty;

  /// "40 XP, 1 Hammer Strike".
  String get label => [
    if (xp > 0) '$xp XP',
    for (final e in hints.entries) '${e.value} ${e.key.title}${e.value == 1 ? '' : 's'}',
  ].join(', ');
}

class StokeInfo {
  const StokeInfo({required this.day, required this.claimedToday, required this.track});

  factory StokeInfo.fromJson(Map<String, dynamic> j) => StokeInfo(
    day: (j['day'] as num?)?.toInt() ?? 1,
    claimedToday: j['claimedToday'] as bool? ?? false,
    track: [for (final r in (j['track'] as List? ?? const [])) Reward.fromJson((r as Map).cast())],
  );

  /// 1–7: the step today's claim gives, or gave.
  final int day;
  final bool claimedToday;
  final List<Reward> track;
}

class WorkOrder {
  const WorkOrder({
    required this.slot,
    required this.kind,
    required this.target,
    required this.progress,
    required this.reward,
    required this.claimed,
    this.letter,
    this.friends = false,
  });

  factory WorkOrder.fromJson(Map<String, dynamic> j) => WorkOrder(
    slot: j['slot'] as String,
    kind: j['kind'] as String,
    target: (j['target'] as num?)?.toInt() ?? 1,
    progress: (j['progress'] as num?)?.toInt() ?? 0,
    letter: j['letter'] as String?,
    friends: j['friends'] as bool? ?? false,
    reward: Reward.fromJson((j['reward'] as Map?)?.cast()),
    claimed: j['claimed'] as bool? ?? false,
  );

  final String slot;
  final String kind;
  final int target;
  final int progress;
  final String? letter;

  /// Needs other players (co-op or Versus).
  final bool friends;
  final Reward reward;
  final bool claimed;

  bool get done => progress >= target;
  bool get claimable => done && !claimed;
  bool get daily => slot.startsWith('d');

  /// What to do, in the forge's words.
  String get title => switch (kind) {
    'solo_puzzles' => 'Forge $target campaign puzzle${target == 1 ? '' : 's'}',
    'bonus_words' => 'Find $target bonus words',
    'words' => 'Forge $target words',
    'long_words' => 'Forge $target words of 6+ letters',
    'daily' => 'Complete the Daily Commission',
    'no_hints' => 'Forge a campaign puzzle without hints',
    'coop_rounds' => 'Play a Co-op round with friends',
    'vs_series' => 'Finish a Versus series with friends',
    'letter_hunt' => 'Letter Hunt: forge $target words with ${letter ?? '?'}',
    _ => 'A special order',
  };
}

class OrdersInfo {
  const OrdersInfo({
    required this.daily,
    required this.weekly,
    required this.chestReward,
    required this.chestReady,
    required this.chestClaimed,
    required this.swapAvailable,
    required this.dailyEndsAt,
    required this.weeklyEndsAt,
  });

  factory OrdersInfo.fromJson(Map<String, dynamic> j) {
    final chest = (j['chest'] as Map?)?.cast<String, dynamic>() ?? const {};
    return OrdersInfo(
      daily: [for (final o in (j['daily'] as List? ?? const [])) WorkOrder.fromJson((o as Map).cast())],
      weekly: [for (final o in (j['weekly'] as List? ?? const [])) WorkOrder.fromJson((o as Map).cast())],
      chestReward: Reward.fromJson((chest['reward'] as Map?)?.cast()),
      chestReady: chest['ready'] as bool? ?? false,
      chestClaimed: chest['claimed'] as bool? ?? false,
      swapAvailable: j['swapAvailable'] as bool? ?? false,
      dailyEndsAt: DateTime.fromMillisecondsSinceEpoch((j['dailyEndsAt'] as num?)?.toInt() ?? 0, isUtc: true),
      weeklyEndsAt: DateTime.fromMillisecondsSinceEpoch((j['weeklyEndsAt'] as num?)?.toInt() ?? 0, isUtc: true),
    );
  }

  final List<WorkOrder> daily;
  final List<WorkOrder> weekly;
  final Reward chestReward;

  /// All three daily orders are claimed, so the chest can be opened.
  final bool chestReady;
  final bool chestClaimed;
  final bool swapAvailable;
  final DateTime dailyEndsAt;
  final DateTime weeklyEndsAt;

  int get claimable =>
      [...daily, ...weekly].where((o) => o.claimable).length + (chestReady && !chestClaimed ? 1 : 0);
}

class TrialStanding {
  const TrialStanding({
    required this.id,
    required this.username,
    required this.avatar,
    required this.level,
    required this.xp,
    required this.me,
  });

  factory TrialStanding.fromJson(Map<String, dynamic> j) => TrialStanding(
    id: j['id'] as String,
    username: j['username'] as String? ?? '?',
    avatar: j['avatar'] as String? ?? 'avatar_01',
    level: (j['level'] as num?)?.toInt() ?? 1,
    xp: (j['xp'] as num?)?.toInt() ?? 0,
    me: j['me'] as bool? ?? false,
  );

  final String id;
  final String username;
  final String avatar;
  final int level;
  final int xp;
  final bool me;
}

class LastWeek {
  const LastWeek({required this.week, required this.place, required this.of, required this.reward, required this.claimed});

  factory LastWeek.fromJson(Map<String, dynamic> j) => LastWeek(
    week: j['week'] as String? ?? '',
    place: (j['place'] as num?)?.toInt() ?? 0,
    of: (j['of'] as num?)?.toInt() ?? 0,
    reward: j['reward'] == null ? null : Reward.fromJson((j['reward'] as Map).cast()),
    claimed: j['claimed'] as bool? ?? false,
  );

  final String week;
  final int place;
  final int of;

  /// Null when last week earned no prize.
  final Reward? reward;
  final bool claimed;

  bool get claimable => reward != null && !claimed;
}

class TrialsInfo {
  const TrialsInfo({required this.week, required this.endsAt, required this.standings, this.lastWeek});

  factory TrialsInfo.fromJson(Map<String, dynamic> j) => TrialsInfo(
    week: j['week'] as String? ?? '',
    endsAt: DateTime.fromMillisecondsSinceEpoch((j['endsAt'] as num?)?.toInt() ?? 0, isUtc: true),
    standings: [
      for (final s in (j['standings'] as List? ?? const [])) TrialStanding.fromJson((s as Map).cast()),
    ],
    lastWeek: j['lastWeek'] == null ? null : LastWeek.fromJson((j['lastWeek'] as Map).cast()),
  );

  final String week;
  final DateTime endsAt;
  final List<TrialStanding> standings;
  final LastWeek? lastWeek;
}

class Gift {
  const Gift({required this.id, required this.fromId, required this.fromName, required this.fromAvatar});

  factory Gift.fromJson(Map<String, dynamic> j) {
    final from = (j['from'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Gift(
      id: (j['id'] as num?)?.toInt() ?? 0,
      fromId: from['id'] as String? ?? '',
      fromName: from['username'] as String? ?? '?',
      fromAvatar: from['avatar'] as String? ?? 'avatar_01',
    );
  }

  final int id;
  final String fromId;
  final String fromName;
  final String fromAvatar;
}

class GiftsInfo {
  const GiftsInfo({
    required this.pending,
    required this.sentToday,
    required this.claimedToday,
    required this.claimLimit,
  });

  factory GiftsInfo.fromJson(Map<String, dynamic> j) => GiftsInfo(
    pending: [for (final g in (j['pending'] as List? ?? const [])) Gift.fromJson((g as Map).cast())],
    sentToday: {...((j['sentToday'] as List?) ?? const []).cast<String>()},
    claimedToday: (j['claimedToday'] as num?)?.toInt() ?? 0,
    claimLimit: (j['claimLimit'] as num?)?.toInt() ?? 5,
  );

  final List<Gift> pending;
  final Set<String> sentToday;
  final int claimedToday;
  final int claimLimit;

  bool get canClaim => pending.isNotEmpty && claimedToday < claimLimit;
}

class ForgeBoard {
  const ForgeBoard({
    required this.date,
    required this.stoke,
    required this.orders,
    required this.trials,
    required this.gifts,
  });

  factory ForgeBoard.fromJson(Map<String, dynamic> j) => ForgeBoard(
    date: j['date'] as String? ?? '',
    stoke: StokeInfo.fromJson((j['stoke'] as Map?)?.cast() ?? const {}),
    orders: OrdersInfo.fromJson((j['orders'] as Map?)?.cast() ?? const {}),
    trials: TrialsInfo.fromJson((j['trials'] as Map?)?.cast() ?? const {}),
    gifts: GiftsInfo.fromJson((j['gifts'] as Map?)?.cast() ?? const {}),
  );

  final String date;
  final StokeInfo stoke;
  final OrdersInfo orders;
  final TrialsInfo trials;
  final GiftsInfo gifts;

  /// Rewards waiting to be claimed: the badge on the Forge Hall's button.
  int get waiting =>
      (stoke.claimedToday ? 0 : 1) +
      orders.claimable +
      (trials.lastWeek?.claimable == true ? 1 : 0) +
      (gifts.canClaim ? 1 : 0);
}

/// What a claim on the board answers.
class BoardClaim {
  const BoardClaim({required this.profile, required this.board, required this.reward});

  factory BoardClaim.fromJson(Map<String, dynamic> j) => BoardClaim(
    profile: ServerProfile.fromJson((j['profile'] as Map).cast()),
    board: ForgeBoard.fromJson((j['board'] as Map).cast()),
    reward: Reward.fromJson((j['reward'] as Map?)?.cast()),
  );

  final ServerProfile profile;
  final ForgeBoard board;
  final Reward reward;
}
