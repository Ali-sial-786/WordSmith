import 'package:flutter/material.dart';

import '../theme/palette.dart';
import 'game_icon.dart';

/// The 16 emblem avatars (assets/icons/avatar_01.svg … avatar_16.svg).
final avatarIds = [for (var i = 1; i <= 16; i++) 'avatar_${i.toString().padLeft(2, '0')}'];

/// An avatar emblem on a round metal badge.
class AvatarBadge extends StatelessWidget {
  const AvatarBadge({super.key, required this.avatar, this.size = 48, this.selected = false, this.presence});

  final String avatar;
  final double size;
  final bool selected;

  /// Shows a status dot when set: `online`, `solo`, `in_room:…` or `offline`.
  final String? presence;

  @override
  Widget build(BuildContext context) {
    final dot = switch (presence) {
      null => null,
      'offline' => Palette.iron,
      'solo' => Palette.molten,
      final s when s.startsWith('in_room:') => Palette.ember,
      _ => Palette.verdigris,
    };
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(center: const Alignment(-0.3, -0.4), colors: Palette.roundFace),
              border: Border.all(color: selected ? Palette.molten : Palette.rim, width: selected ? 3 : 1.5),
              boxShadow: [if (selected) BoxShadow(color: Palette.ember.withValues(alpha: 0.6), blurRadius: 12)],
            ),
            child: Center(
              child: GameIcon(avatar, size: size * 0.58, color: Palette.whiteHeat),
            ),
          ),
          if (dot != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: size * 0.28,
                height: size * 0.28,
                decoration: BoxDecoration(
                  color: dot,
                  shape: BoxShape.circle,
                  border: Border.all(color: Palette.forgeBlack, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Words for a friend's status.
String presenceLabel(String? status) => switch (status) {
  null || 'offline' => 'Offline',
  'online' => 'Online',
  'solo' => 'Forging solo',
  final s when s.startsWith('in_room:') => 'In room ${s.substring(8)}',
  _ => 'Online',
};
