import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../game/account.dart';
import '../../net/api_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/metal_button.dart';

/// Room codes use these characters (no 0/O or 1/I look-alikes).
const roomCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// Start or join a co-op room.
Future<void> showCoopEntry(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Palette.soot,
  builder: (_) => const _CoopEntrySheet(),
);

class _CoopEntrySheet extends ConsumerStatefulWidget {
  const _CoopEntrySheet();

  @override
  ConsumerState<_CoopEntrySheet> createState() => _CoopEntrySheetState();
}

class _CoopEntrySheetState extends ConsumerState<_CoopEntrySheet> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String> Function() getCode) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final code = await getCode();
      if (!mounted) return;
      Navigator.of(context).pop();
      GoRouter.of(context).push('/room/$code');
    } on ApiException catch (e) {
      setState(() => _error = e.friendly);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join(String code) => _run(() async {
    await ref.read(accountProvider.notifier).checkRoom(code);
    return code;
  });

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final rooms = account.openRooms.where((r) => r.mode == 'coop').toList();
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(22, 22, 22, 22 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('The Guild Forge', textAlign: TextAlign.center, style: displayStyle(24, color: Palette.molten)),
          const SizedBox(height: 4),
          Text(
            'Up to 4 smiths, one mold, one timer. First to forge a word scores it.',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: Palette.steel),
          ),
          const SizedBox(height: 18),
          PlateButton(
            label: 'Light a forge',
            sublabel: 'You host; your level sets the heat',
            icon: 'anvil',
            primary: true,
            onPressed: _busy ? null : () => _run(() => ref.read(accountProvider.notifier).createRoom('coop')),
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
                    TextInputFormatter.withFunction(
                      (_, v) => v.copyWith(text: v.text.toUpperCase()),
                    ),
                  ],
                  style: letterStyle(22).copyWith(letterSpacing: 6),
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
            Text("Friends' forges", style: text.titleMedium),
            for (final r in rooms)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text("${r.hostUsername}'s forge"),
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
