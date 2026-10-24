import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../game/account.dart';
import '../../game/names.dart';
import '../../net/api_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/metal_button.dart';

/// Room codes use these characters (no 0/O or 1/I look-alikes).
const roomCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// Start or join a co-op room.
Future<void> showCoopEntry(BuildContext context) => showRoomEntry(context, 'coop');

/// What a room mode is called: Co-op, Versus or Team Versus.
String modeName(String mode) => switch (mode) {
  'vs' => 'Versus',
  'team' => 'Team Versus',
  _ => 'Co-op',
};

/// Start or join a room: `coop`, `vs` or `team`.
Future<void> showRoomEntry(BuildContext context, String mode) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Palette.soot,
  builder: (_) => _RoomEntrySheet(mode: mode),
);

class _RoomEntrySheet extends ConsumerStatefulWidget {
  const _RoomEntrySheet({required this.mode});

  final String mode;

  @override
  ConsumerState<_RoomEntrySheet> createState() => _RoomEntrySheetState();
}

class _RoomEntrySheetState extends ConsumerState<_RoomEntrySheet> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  bool get _vs => widget.mode != 'coop';
  bool get _team => widget.mode == 'team';

  /// [getRoom] returns the room's code and mode.
  Future<void> _run(Future<(String, String)> Function() getRoom) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final (code, mode) = await getRoom();
      if (!mounted) return;
      Navigator.of(context).pop();
      GoRouter.of(context).push('/room/$code?mode=$mode');
    } on ApiException catch (e) {
      setState(() => _error = e.friendly);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join(String code) => _run(() async {
    final mode = await ref.read(accountProvider.notifier).checkRoom(code);
    return (code, mode);
  });

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final rooms = account.openRooms.where((r) => r.mode == widget.mode).toList();
    final names = ref.watch(displayNamesProvider);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(22, 22, 22, 22 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _team
                ? 'Team Clash'
                : _vs
                ? 'Anvil Clash'
                : 'The Guild Forge',
            textAlign: TextAlign.center,
            style: displayStyle(24, color: Palette.molten),
          ),
          const SizedBox(height: 4),
          Text(
            _team
                ? 'Two teams of 1 to 3 smiths, each on their own mold. Win rounds on letters added up, or by '
                      'being first to finish; best of 3, 5, 7 or 10.'
                : _vs
                ? 'Up to 5 smiths race the same puzzle. First to fill their mold wins the round; best of 3, 5, 7 or '
                      '10, or play on the total score.'
                : 'Up to 4 smiths, one mold, one timer. First to forge a word scores it.',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: Palette.steel),
          ),
          const SizedBox(height: 18),
          PlateButton(
            label: _vs ? 'Call a clash' : 'Light a forge',
            sublabel: _team
                ? 'You host; pick how rounds are won'
                : _vs
                ? 'You host and pick the series length'
                : 'You host; your level sets the heat',
            icon: _vs ? 'trophy' : 'anvil',
            primary: true,
            onPressed: _busy
                ? null
                : () =>
                      _run(() async => (await ref.read(accountProvider.notifier).createRoom(widget.mode), widget.mode)),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _code,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 6,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                    TextInputFormatter.withFunction((_, v) => v.copyWith(text: v.text.toUpperCase())),
                  ],
                  style: letterStyle(22, color: Palette.gold).copyWith(letterSpacing: 6),
                  decoration: const InputDecoration(labelText: 'Room code', counterText: ''),
                  onSubmitted: (v) => v.length == 6 ? _join(v) : null,
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Palette.ember),
                onPressed: _busy
                    ? null
                    : () {
                        final code = _code.text.trim();
                        if (code.length != 6 || code.split('').any((c) => !roomCodeAlphabet.contains(c))) {
                          setState(() => _error = 'Codes are 6 letters and numbers.');
                          return;
                        }
                        _join(code);
                      },
                child: const Text('Join'),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: text.bodyMedium?.copyWith(color: Palette.quenchRed)),
          ],
          if (rooms.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(_vs ? "Friends' clashes" : "Friends' forges", style: text.titleMedium),
            for (final r in rooms)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text("${names.of(r.hostId, r.hostUsername)}'s ${_vs ? 'clash' : 'forge'}"),
                subtitle: Text('${r.players}/${r.max} smiths · ${r.code}'),
                trailing: TextButton(
                  onPressed: _busy || r.players >= r.max ? null : () => _join(r.code),
                  child: const Text('Join'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
