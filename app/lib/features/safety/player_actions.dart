import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../game/account.dart';
import '../../game/room_session.dart';
import '../../net/api_client.dart';
import '../../net/models.dart';
import '../../net/room_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/web_links.dart';

/// What can be done about another player (shared/safety.md): mute them for
/// this room, block them everywhere, or report them. From room chat, the
/// lobby and the friends list. [session] is the room, when there is one.
Future<void> showPlayerActions(
  BuildContext context,
  WidgetRef ref, {
  required String userId,
  required String name,
  String avatar = 'avatar_01',
  RoomSession? session,
}) {
  // Read now: the sheet (and its own ref) is gone by the time a block lands.
  final accounts = ref.read(accountProvider.notifier);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: Palette.soot,
    builder: (sheet) => Consumer(
      builder: (sheet, sheetRef, _) {
        final account = sheetRef.watch(accountProvider);
        final blocked = account.blocked.any((b) => b.id == userId);
        final muted = session?.muted.contains(userId) ?? false;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(name, style: displayStyle(20, color: Palette.molten)),
              ),
              if (session != null)
                ListTile(
                  leading: Icon(muted ? Icons.volume_up_outlined : Icons.speaker_notes_off_outlined),
                  title: Text(muted ? 'Unmute in this room' : 'Mute in this room'),
                  subtitle: Text(muted ? 'See their messages again' : 'Hide their messages until you leave the room'),
                  onTap: () {
                    Navigator.pop(sheet);
                    muted ? session.unmute(userId) : session.mute(userId);
                  },
                ),
              if (account.isReady)
                ListTile(
                  leading: Icon(blocked ? Icons.lock_open : Icons.block, color: blocked ? null : Palette.quenchRed),
                  title: Text(blocked ? 'Unblock $name' : 'Block $name'),
                  subtitle: Text(
                    blocked
                        ? 'Their messages show again; you can be friends again'
                        : "Hide their messages everywhere and stop friend requests. They won't be told.",
                  ),
                  onTap: () async {
                    Navigator.pop(sheet);
                    if (blocked) {
                      await _run(context, () => accounts.unblock(userId), 'Unblocked $name.');
                    } else if (await _confirmBlock(context, name)) {
                      if (!context.mounted) return;
                      await _run(
                        context,
                        () => accounts.block(userId, username: name, avatar: avatar),
                        'Blocked $name. Unblock them any time in Settings.',
                      );
                    }
                  },
                ),
              if (account.isReady)
                ListTile(
                  leading: Icon(Icons.flag_outlined, color: Palette.quenchRed),
                  title: Text('Report $name'),
                  subtitle: const Text('Tell us about bullying, hate, cheating or a bad name'),
                  onTap: () {
                    Navigator.pop(sheet);
                    showReportSheet(
                      context,
                      ref,
                      userId: userId,
                      name: name,
                      room: session?.lobby?.code,
                      lines: [
                        for (final l in session?.chat ?? const <ChatLine>[])
                          if (l.from == userId) l,
                      ],
                    );
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ),
  );
}

Future<bool> _confirmBlock(BuildContext context, String name) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Block $name?'),
        content: Text(
          "You won't see $name's messages or emotes in any room, and you won't be friends any more. "
          "They won't be told. You can unblock them in Settings.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Block')),
        ],
      ),
    ) ??
    false;

Future<void> _run(BuildContext context, Future<void> Function() action, String done) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await action();
    messenger?.showSnackBar(SnackBar(content: Text(done)));
  } on ApiException catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(e.friendly)));
  }
}

/// Reports [userId] with a reason and, optionally, what happened. Their
/// chat lines from this room go with it, so it can be checked.
Future<void> showReportSheet(
  BuildContext context,
  WidgetRef ref, {
  required String userId,
  required String name,
  String? room,
  List<ChatLine> lines = const [],
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: Palette.soot,
  builder: (_) => _ReportSheet(userId: userId, name: name, room: room, lines: lines),
);

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({required this.userId, required this.name, this.room, this.lines = const []});

  final String userId;
  final String name;
  final String? room;
  final List<ChatLine> lines;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  ReportReason? _reason;
  final _details = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(accountProvider.notifier)
          .report(
            userId: widget.userId,
            reason: reason,
            details: _details.text,
            room: widget.room,
            lines: widget.lines,
          );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.pop(context);
      messenger?.showSnackBar(
        const SnackBar(content: Text('Report sent. Thanks for helping keep the forge friendly.')),
      );
    } on ApiException catch (e) {
      if (mounted) {
        setState(
          () => _error = e.code == 'too_many_reports'
              ? "You've sent a lot of reports today. Try again tomorrow."
              : e.friendly,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Report ${widget.name}', style: displayStyle(20, color: Palette.molten)),
            const SizedBox(height: 4),
            Text('What happened?', style: text.titleSmall),
            RadioGroup<ReportReason>(
              groupValue: _reason,
              onChanged: (r) => setState(() => _reason = r),
              child: Column(
                children: [
                  for (final r in ReportReason.values)
                    RadioListTile<ReportReason>(
                      value: r,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(r.label),
                    ),
                ],
              ),
            ),
            TextField(
              controller: _details,
              maxLength: 500,
              maxLines: 3,
              minLines: 2,
              style: fieldText(),
              decoration: const InputDecoration(
                labelText: 'Details (optional)',
                hintText: 'Anything else we should know?',
              ),
            ),
            if (widget.lines.isNotEmpty)
              Text(
                'Their ${widget.lines.length == 1 ? 'message' : '${widget.lines.length} messages'} in this room '
                'will be sent with your report.',
                style: text.bodySmall,
              ),
            const SizedBox(height: 4),
            Text(
              "${widget.name} won't know who reported them. To stop seeing them, block them too.",
              style: text.bodySmall,
            ),
            TextButton(
              style: TextButton.styleFrom(alignment: Alignment.centerLeft, padding: EdgeInsets.zero),
              onPressed: () => openWebPage(context, WebPage.terms),
              child: const Text('Read the chat rules'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, style: TextStyle(color: Palette.quenchRed)),
              ),
            FilledButton(
              onPressed: _reason == null || _busy ? null : _send,
              child: Text(_busy ? 'Sending…' : 'Send report'),
            ),
          ],
        ),
      ),
    );
  }
}
