import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/providers.dart';
import '../../game/room_session.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/gold_field.dart';
import '../../ui/widgets/web_links.dart';
import '../safety/player_actions.dart';

/// Quick lines under the chat box, one tap to send (handy mid-round).
const chatPhrases = ['Good luck!', 'Nice one!', 'So close!', 'Ready when you are', 'Again?', 'gg'];

/// The longest line, in characters; the server cuts anything longer.
const chatMaxLength = 160;

/// Opens the room's chat; while it's open, new lines count as read.
Future<void> showRoomChat(BuildContext context, RoomSession session) async {
  session.openChat();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Palette.soot,
    builder: (_) => RoomChatSheet(session: session),
  );
  session.closeChat();
}

/// The chat button, with how many lines came since I last looked.
class ChatButton extends StatelessWidget {
  const ChatButton({super.key, required this.session, this.size = 22});

  final RoomSession session;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (!session.chatEnabled) return const SizedBox.shrink();
    final unread = session.unreadChat;
    return IconButton(
      tooltip: 'Chat',
      visualDensity: VisualDensity.compact,
      onPressed: () => showRoomChat(context, session),
      icon: Badge(
        isLabelVisible: unread > 0,
        backgroundColor: Palette.ember,
        textColor: Palette.onAccent,
        label: Text(unread > 9 ? '9+' : '$unread'),
        child: Icon(
          unread > 0 ? Icons.chat_bubble : Icons.chat_bubble_outline,
          size: size,
          color: unread > 0 ? Palette.molten : Palette.steel,
        ),
      ),
    );
  }
}

/// A view's title with the chat button at its right, the title still centred.
class ChatTitle extends StatelessWidget {
  const ChatTitle({super.key, required this.session, required this.child});

  final RoomSession session;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!session.chatEnabled) return child;
    return Row(
      children: [
        const SizedBox(width: 40),
        Expanded(child: child),
        ChatButton(session: session),
      ],
    );
  }
}

/// The newest line from someone else, shown for a moment over the room
/// while the chat is closed; a tap opens the chat.
class ChatToast extends StatelessWidget {
  const ChatToast({super.key, required this.session, required this.line, required this.onTap});

  final RoomSession session;
  final ChatLine line;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = Palette.legible(session.colorOf(line.from));
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340),
          padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
          decoration: BoxDecoration(
            color: Palette.soot.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color, width: 1.6),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 3))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble, size: 16, color: color),
              const SizedBox(width: 8),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${session.chatName(line)}  ',
                        style: TextStyle(color: color, fontWeight: FontWeight.w800),
                      ),
                      TextSpan(text: line.text),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(color: Palette.whiteHeat),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The room's chat: everything said since I joined (and the room's last 50
/// lines from before), a box to write in and quick phrases. A long press on
/// someone's line mutes them for this room.
class RoomChatSheet extends ConsumerStatefulWidget {
  const RoomChatSheet({super.key, required this.session});

  final RoomSession session;

  @override
  ConsumerState<RoomChatSheet> createState() => _RoomChatSheetState();
}

class _RoomChatSheetState extends ConsumerState<RoomChatSheet> {
  /// The chat rules, shown until dismissed once.
  late bool _rules = !ref.read(storeProvider).seenTip('chat_rules');

  final _text = TextEditingController();
  StreamSubscription<RoomEvent>? _errors;

  /// The server said I'm writing too fast.
  bool _slow = false;
  Timer? _slowTimer;

  RoomSession get _s => widget.session;

  @override
  void initState() {
    super.initState();
    _errors = _s.effects.listen((e) {
      if (e is RoomError && e.code == 'chat_limit' && mounted) {
        setState(() => _slow = true);
        _slowTimer?.cancel();
        _slowTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _slow = false);
        });
      }
    });
  }

  @override
  void dispose() {
    _errors?.cancel();
    _slowTimer?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _send(String text) {
    if (text.trim().isEmpty) return;
    _s.sendChat(text);
    _text.clear();
  }

  /// Mute, block or report whoever wrote [line].
  void _actions(ChatLine line) {
    final player = _s.lobby?.player(line.from);
    showPlayerActions(
      context,
      ref,
      userId: line.from,
      name: _s.chatName(line),
      avatar: player?.avatar ?? 'avatar_01',
      session: _s,
    );
  }

  void _dismissRules() {
    ref.read(storeProvider).markTip('chat_rules');
    setState(() => _rules = false);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final height = MediaQuery.sizeOf(context).height;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ListenableBuilder(
        listenable: _s,
        builder: (context, _) {
          final lines = _s.visibleChat.reversed.toList();
          final names = {for (final l in _s.chat) l.from: _s.chatName(l)};
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: height * 0.62),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('Forge chat', style: displayStyle(20, color: Palette.molten)),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(Icons.close, color: Palette.steel),
                      ),
                    ],
                  ),
                  if (_rules)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
                      decoration: BoxDecoration(
                        color: Palette.forgeBlack.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Palette.gold.withValues(alpha: 0.6)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Be kind in the forge: no bullying, hate or sharing anyone's personal details. Swear "
                            "words are starred out. Hold someone's message to mute, block or report them.",
                            style: text.bodySmall,
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => openWebPage(context, WebPage.terms),
                                child: const Text('Chat rules'),
                              ),
                              TextButton(onPressed: _dismissRules, child: const Text('Got it')),
                            ],
                          ),
                        ],
                      ),
                    ),
                  if (_s.muted.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('Muted:', style: text.bodySmall),
                          for (final id in _s.muted)
                            InputChip(
                              label: Text(names[id] ?? _s.nameOf(id)),
                              deleteIcon: const Icon(Icons.close, size: 16),
                              deleteButtonTooltipMessage: 'Unmute',
                              onDeleted: () => _s.unmute(id),
                            ),
                        ],
                      ),
                    ),
                  Flexible(
                    child: lines.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 28),
                            child: Text(
                              'Nothing said yet. Say hello to the forge!',
                              textAlign: TextAlign.center,
                              style: text.bodyMedium?.copyWith(color: Palette.steel),
                            ),
                          )
                        : ListView.builder(
                            reverse: true,
                            shrinkWrap: true,
                            itemCount: lines.length,
                            itemBuilder: (context, i) {
                              final line = lines[i];
                              final mine = line.from == _s.me;
                              return _ChatBubble(
                                name: mine ? 'You' : _s.chatName(line),
                                text: line.text,
                                color: Palette.legible(_s.colorOf(line.from)),
                                mine: mine,
                                onLongPress: mine ? null : () => _actions(line),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 36,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final p in chatPhrases)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ActionChip(
                              label: Text(p),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _send(p),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_slow)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Easy on the bellows: wait a moment before the next one.',
                        style: text.bodySmall?.copyWith(color: Palette.quenchRed),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: GoldTextField(
                          controller: _text,
                          hint: 'Message the room',
                          textInputAction: TextInputAction.send,
                          inputFormatters: [LengthLimitingTextInputFormatter(chatMaxLength)],
                          onSubmitted: _send,
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filled(
                        tooltip: 'Send',
                        style: IconButton.styleFrom(backgroundColor: Palette.molten, foregroundColor: Palette.onAccent),
                        onPressed: () => _send(_text.text),
                        icon: const Icon(Icons.send),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.name,
    required this.text,
    required this.color,
    required this.mine,
    this.onLongPress,
  });

  final String name;
  final String text;
  final Color color;
  final bool mine;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          decoration: BoxDecoration(
            color: mine ? Palette.molten.withValues(alpha: 0.16) : Palette.forgeBlack.withValues(alpha: 0.6),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(14),
              topRight: const Radius.circular(14),
              bottomLeft: Radius.circular(mine ? 14 : 4),
              bottomRight: Radius.circular(mine ? 4 : 14),
            ),
            border: Border.all(color: color.withValues(alpha: 0.85), width: 1.4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: style.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(text, style: style.bodyMedium?.copyWith(color: Palette.whiteHeat)),
            ],
          ),
        ),
      ),
    );
  }
}
