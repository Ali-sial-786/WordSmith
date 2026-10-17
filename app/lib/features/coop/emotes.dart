import 'package:flutter/material.dart';

import '../../ui/theme/palette.dart';

/// The preset emotes (there's no text chat).
const emoteIds = ['nice', 'close', 'fire', 'hammer', 'gg'];

String emoteText(String id) => switch (id) {
  'nice' => 'Nice strike!',
  'close' => 'So close!',
  'fire' => '🔥',
  'hammer' => '🔨',
  'gg' => 'Good game!',
  _ => id,
};

/// Opens the emote list; picking one sends it to the room.
class EmoteButton extends StatelessWidget {
  const EmoteButton({super.key, required this.onEmote, this.size = 22});

  final ValueChanged<String> onEmote;
  final double size;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Emotes',
    color: Palette.soot,
    icon: Icon(Icons.emoji_emotions_outlined, size: size, color: Palette.steel),
    onSelected: onEmote,
    itemBuilder: (_) => [for (final id in emoteIds) PopupMenuItem(value: id, child: Text(emoteText(id)))],
  );
}
