import '../engine/hints.dart';
import '../engine/progression.dart';

class Stats {
  const Stats({this.wordsForged = 0, this.bonusWords = 0, this.longestWord = '', this.soloDone = 0});

  factory Stats.fromJson(Map<String, dynamic> json) => Stats(
    wordsForged: json['wordsForged'] as int? ?? 0,
    bonusWords: json['bonusWords'] as int? ?? 0,
    longestWord: json['longestWord'] as String? ?? '',
    soloDone: json['soloDone'] as int? ?? 0,
  );

  final int wordsForged;
  final int bonusWords;
  final String longestWord;
  final int soloDone;

  Stats copyWith({int? wordsForged, int? bonusWords, String? longestWord, int? soloDone}) => Stats(
    wordsForged: wordsForged ?? this.wordsForged,
    bonusWords: bonusWords ?? this.bonusWords,
    longestWord: longestWord ?? this.longestWord,
    soloDone: soloDone ?? this.soloDone,
  );

  Map<String, Object> toJson() => {
    'wordsForged': wordsForged,
    'bonusWords': bonusWords,
    'longestWord': longestWord,
    'soloDone': soloDone,
  };
}

/// The local player profile. From M2 the server owns these numbers and the
/// phone keeps a cache.
class Profile {
  const Profile({
    required this.userId,
    this.totalXp = 0,
    this.campaignStage = 1,
    this.scrapBin = 0,
    this.hints = const {HintKind.hammer: startingHammers},
    this.stats = const Stats(),
    this.masterworkPieces = 0,
  });

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    userId: json['userId'] as String,
    totalXp: json['totalXp'] as int? ?? 0,
    campaignStage: json['campaignStage'] as int? ?? 1,
    scrapBin: json['scrapBin'] as int? ?? 0,
    hints: json['hints'] == null
        ? const {HintKind.hammer: startingHammers}
        : {for (final e in (json['hints'] as Map).entries) HintKind.byName(e.key as String): e.value as int},
    stats: Stats.fromJson((json['stats'] as Map?)?.cast() ?? const {}),
    masterworkPieces: json['masterworkPieces'] as int? ?? 0,
  );

  /// Install ID until accounts arrive; the account ID afterwards.
  final String userId;
  final int totalXp;

  /// Next campaign stage to play (1-based).
  final int campaignStage;
  final int scrapBin;
  final Map<HintKind, int> hints;
  final Stats stats;

  /// Blueprint pieces collected from gilded cells (shared/masterworks.md).
  final int masterworkPieces;

  LevelProgress get progress => levelForTotalXp(totalXp);
  int get level => progress.level;
  Rank get rank => Rank.forLevel(level);

  int hintCount(HintKind kind) => hints[kind] ?? 0;

  Profile copyWith({
    String? userId,
    int? totalXp,
    int? campaignStage,
    int? scrapBin,
    Map<HintKind, int>? hints,
    Stats? stats,
    int? masterworkPieces,
  }) => Profile(
    userId: userId ?? this.userId,
    totalXp: totalXp ?? this.totalXp,
    campaignStage: campaignStage ?? this.campaignStage,
    scrapBin: scrapBin ?? this.scrapBin,
    hints: hints ?? this.hints,
    stats: stats ?? this.stats,
    masterworkPieces: masterworkPieces ?? this.masterworkPieces,
  );

  Profile withHints(HintKind kind, int delta) {
    final next = {...hints};
    next[kind] = (next[kind] ?? 0) + delta;
    return copyWith(hints: next);
  }

  Map<String, Object> toJson() => {
    'userId': userId,
    'totalXp': totalXp,
    'campaignStage': campaignStage,
    'scrapBin': scrapBin,
    'hints': {for (final e in hints.entries) e.key.name: e.value},
    'stats': stats.toJson(),
    'masterworkPieces': masterworkPieces,
  };
}

class Settings {
  const Settings({
    this.sfxVolume = 0.9,
    this.musicVolume = 0.6,
    this.ambienceVolume = 0.4,
    this.haptics = true,
    this.reducedMotion = false,
    this.videoChat = true,
    this.videoMic = true,
    this.textChat = true,
    this.inviteNotifications = true,
    this.leftHanded = false,
    this.reminderHour,
    this.colorScheme = 'forge',
    this.font = 'forge',
  });

  factory Settings.fromJson(Map<String, dynamic> json) => Settings(
    sfxVolume: (json['sfx'] as num?)?.toDouble() ?? 0.9,
    musicVolume: (json['music'] as num?)?.toDouble() ?? 0.6,
    ambienceVolume: (json['ambience'] as num?)?.toDouble() ?? 0.4,
    haptics: json['haptics'] as bool? ?? true,
    reducedMotion: json['reducedMotion'] as bool? ?? false,
    // A new key: chat in rooms used to be off by default, and is on now.
    videoChat: json['roomChat'] as bool? ?? true,
    videoMic: json['videoMic'] as bool? ?? true,
    textChat: json['textChat'] as bool? ?? true,
    inviteNotifications: json['inviteNotifications'] as bool? ?? true,
    leftHanded: json['leftHanded'] as bool? ?? false,
    reminderHour: json['reminderHour'] as int?,
    colorScheme: json['colorScheme'] as String? ?? 'forge',
    font: json['font'] as String? ?? 'forge',
  );

  final double sfxVolume;
  final double musicVolume;
  final double ambienceVolume;

  final bool haptics;
  final bool reducedMotion;

  /// Voice chat with friends in Co-op and Versus rooms, on unless turned
  /// off. The camera always starts off; players turn it on in the room.
  final bool videoChat;

  /// Whether the mic starts on when joining a room's chat (the last choice
  /// made in a room).
  final bool videoMic;

  /// Text chat in Co-op and Versus rooms: the chat button and new lines
  /// popping up over the game.
  final bool textChat;

  /// Phone notifications when a friend invites you to a room.
  final bool inviteNotifications;

  /// Hint buttons on the left of the anvil, Turn and the Scrap Bin on the right.
  final bool leftHanded;

  /// Local hour (0–23) for the Daily Commission reminder; null for none.
  final int? reminderHour;

  /// The colour scheme's id (PaletteScheme.all).
  final String colorScheme;

  /// The font choice's id (FontChoice.all).
  final String font;

  Settings copyWith({
    double? sfxVolume,
    double? musicVolume,
    double? ambienceVolume,
    bool? haptics,
    bool? reducedMotion,
    bool? videoChat,
    bool? videoMic,
    bool? textChat,
    bool? inviteNotifications,
    bool? leftHanded,
    int? Function()? reminderHour,
    String? colorScheme,
    String? font,
  }) => Settings(
    sfxVolume: sfxVolume ?? this.sfxVolume,
    musicVolume: musicVolume ?? this.musicVolume,
    ambienceVolume: ambienceVolume ?? this.ambienceVolume,
    haptics: haptics ?? this.haptics,
    reducedMotion: reducedMotion ?? this.reducedMotion,
    videoChat: videoChat ?? this.videoChat,
    videoMic: videoMic ?? this.videoMic,
    textChat: textChat ?? this.textChat,
    inviteNotifications: inviteNotifications ?? this.inviteNotifications,
    leftHanded: leftHanded ?? this.leftHanded,
    reminderHour: reminderHour == null ? this.reminderHour : reminderHour(),
    colorScheme: colorScheme ?? this.colorScheme,
    font: font ?? this.font,
  );

  Map<String, Object> toJson() => {
    'sfx': sfxVolume,
    'music': musicVolume,
    'ambience': ambienceVolume,
    'haptics': haptics,
    'reducedMotion': reducedMotion,
    'roomChat': videoChat,
    'videoMic': videoMic,
    'textChat': textChat,
    'inviteNotifications': inviteNotifications,
    'leftHanded': leftHanded,
    'reminderHour': ?reminderHour,
    'colorScheme': colorScheme,
    'font': font,
  };
}
