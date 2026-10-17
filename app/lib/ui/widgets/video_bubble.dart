import 'package:flutter/material.dart';

import '../../video/video_call.dart';
import '../theme/palette.dart';
import 'avatar_badge.dart';

/// A player's live video in a circle, or their avatar while their camera is
/// off. Glows in their colour while they talk; a small badge shows a muted mic.
class VideoBubble extends StatelessWidget {
  const VideoBubble({
    super.key,
    required this.userId,
    required this.avatar,
    required this.size,
    this.call,
    this.color = Palette.molten,
    this.dimmed = false,
  });

  final String userId;
  final String avatar;
  final double size;
  final VideoCall? call;
  final Color color;

  /// For players who are reconnecting.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final call = this.call;
    if (call == null) return _avatar();
    return ListenableBuilder(listenable: call, builder: (context, _) => _bubble(call));
  }

  Widget _avatar() => Opacity(opacity: dimmed ? 0.4 : 1, child: AvatarBadge(avatar: avatar, size: size));

  Widget _bubble(VideoCall call) {
    final peer = call.peers[userId];
    final view = call.view(userId);
    final speaking = peer?.speaking ?? false;
    final face = view == null
        ? _avatar()
        : Opacity(
            opacity: dimmed ? 0.4 : 1,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Palette.soot,
                border: Border.all(color: color, width: 2),
              ),
              child: ClipOval(child: view),
            ),
          );
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: speaking ? [BoxShadow(color: color, blurRadius: 10, spreadRadius: 2)] : const [],
            ),
            child: face,
          ),
          if (peer != null && !peer.mic)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(color: Palette.soot, shape: BoxShape.circle),
                child: Icon(Icons.mic_off, size: size * 0.3, color: Palette.steel),
              ),
            ),
        ],
      ),
    );
  }
}

/// Camera and mic switches for a room's video chat.
class VideoToggles extends StatelessWidget {
  const VideoToggles({super.key, required this.call, required this.onCamera, required this.onMic, this.size = 22});

  final VideoCall call;
  final VoidCallback onCamera;
  final VoidCallback onMic;
  final double size;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: call,
    builder: (context, _) {
      final ready = call.status == VideoStatus.live || call.status == VideoStatus.reconnecting;
      if (call.status == VideoStatus.connecting) {
        return Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox.square(
            dimension: size * 0.8,
            child: const CircularProgressIndicator(strokeWidth: 2, color: Palette.molten),
          ),
        );
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: call.cameraOn ? 'Turn camera off' : 'Turn camera on',
            iconSize: size,
            visualDensity: VisualDensity.compact,
            onPressed: ready ? onCamera : null,
            icon: Icon(call.cameraOn ? Icons.videocam : Icons.videocam_off, color: call.cameraOn ? Palette.molten : Palette.steel),
          ),
          IconButton(
            tooltip: call.micOn ? 'Mute' : 'Unmute',
            iconSize: size,
            visualDensity: VisualDensity.compact,
            onPressed: ready ? onMic : null,
            icon: Icon(call.micOn ? Icons.mic : Icons.mic_off, color: call.micOn ? Palette.molten : Palette.steel),
          ),
        ],
      );
    },
  );
}
