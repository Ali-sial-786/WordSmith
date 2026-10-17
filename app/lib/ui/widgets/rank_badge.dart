import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../engine/progression.dart';
import '../theme/palette.dart';

/// The badge for a smith rank, in its own metal (assets/icons/rank_*.svg).
class RankBadge extends StatelessWidget {
  const RankBadge({super.key, required this.rank, this.size = 28});

  final Rank rank;
  final double size;

  static String fileFor(Rank rank) => switch (rank) {
    Rank.apprentice => 'rank_apprentice',
    Rank.journeyman => 'rank_journeyman',
    Rank.smith => 'rank_smith',
    Rank.masterSmith => 'rank_master',
    Rank.grandmaster => 'rank_grandmaster',
    Rank.legend => 'rank_legend',
  };

  @override
  Widget build(BuildContext context) => Tooltip(
    message: rank.title,
    child: SvgPicture.asset(
      'assets/icons/${fileFor(rank)}.svg',
      width: size,
      height: size,
      placeholderBuilder: (_) => Icon(Icons.shield_outlined, size: size, color: Palette.molten),
      errorBuilder: (_, _, _) => Icon(Icons.shield_outlined, size: size, color: Palette.molten),
    ),
  );
}
