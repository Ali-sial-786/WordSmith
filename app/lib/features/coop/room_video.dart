import 'package:flutter/material.dart';

import '../../ui/theme/palette.dart';
import '../../ui/widgets/video_bubble.dart';
import '../../video/video_call.dart';

/// A room's video chat as the lobby and round views see it.
class RoomVideo {
  const RoomVideo({
    required this.available,
    required this.call,
    required this.onEnable,
    required this.onDisable,
    required this.onCamera,
    required this.onMic,
  });

  /// No video at all (a build without online play).
  static const none = RoomVideo(
    available: false,
    call: null,
    onEnable: _noop,
    onDisable: _noop,
    onCamera: _noop,
    onMic: _noop,
  );

  static void _noop() {}

  /// This build can do video chat.
  final bool available;

  /// The call, while video chat is on.
  final VideoCall? call;
  final VoidCallback onEnable;
  final VoidCallback onDisable;
  final VoidCallback onCamera;
  final VoidCallback onMic;
}

/// The lobby's video chat row: a switch to join, then camera and mic toggles.
class VideoBar extends StatelessWidget {
  const VideoBar({super.key, required this.video});

  final RoomVideo video;

  @override
  Widget build(BuildContext context) {
    if (!video.available) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final call = video.call;
    if (call == null) {
      return OutlinedButton.icon(
        icon: const Icon(Icons.videocam_outlined),
        label: const Text('Turn on video chat'),
        onPressed: video.onEnable,
      );
    }
    return ListenableBuilder(
      listenable: call,
      builder: (context, _) {
        final label = switch (call.status) {
          VideoStatus.connecting => 'Connecting video…',
          VideoStatus.reconnecting => 'Video reconnecting…',
          VideoStatus.failed => 'Video chat is off',
          _ => 'Video chat on',
        };
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
          decoration: BoxDecoration(
            color: Palette.soot,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Palette.ash),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.videocam, size: 18, color: Palette.steel),
                  const SizedBox(width: 8),
                  Expanded(child: Text(label, style: text.bodyMedium)),
                  if (call.status != VideoStatus.failed)
                    VideoToggles(call: call, onCamera: video.onCamera, onMic: video.onMic),
                  TextButton(onPressed: video.onDisable, child: const Text('Turn off')),
                ],
              ),
              if (call.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(call.error!, style: text.bodySmall?.copyWith(color: Palette.quenchRed)),
                ),
            ],
          ),
        );
      },
    );
  }
}
