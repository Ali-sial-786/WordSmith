import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/diagnostics.dart';
import '../../game/providers.dart';
import '../theme/palette.dart';
import 'game_icon.dart';

/// Copies [crash] as a text report, with the device and recent app errors.
Future<void> copyCrashReport(WidgetRef ref, CrashReport crash) async {
  final device = await ref.read(diagnosticsProvider).device();
  final text = crash.toText(device: device, errors: ref.read(storeProvider).loadErrors());
  await Clipboard.setData(ClipboardData(text: text));
}

/// Says once, on the Hall, that the game crashed last time, and offers the
/// report. Draws nothing.
class CrashNotice extends ConsumerStatefulWidget {
  const CrashNotice({super.key});

  @override
  ConsumerState<CrashNotice> createState() => _CrashNoticeState();
}

class _CrashNoticeState extends ConsumerState<CrashNotice> {
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final crash = await ref.read(lastCrashProvider.future);
    final store = ref.read(storeProvider);
    final at = crash?.at.millisecondsSinceEpoch ?? 0;
    if (crash == null || at <= store.crashSeenAt || !mounted) return;
    store.crashSeenAt = at;
    final graphics = await ref.read(graphicsProvider.future);
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
    final copy = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: GameIcon('ember', size: 40, color: Palette.molten),
        title: const Text('The forge went cold'),
        content: Text(
          'Wordsmith closed unexpectedly last time. '
          '${graphics?.auto ?? false ? "We've switched to compatibility graphics, which should stop it. " : ''}'
          'You can copy a crash report to send to whoever shared the game with you.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('OK')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Copy report')),
        ],
      ),
    );
    if (copy != true || !mounted) return;
    await copyCrashReport(ref, crash);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Crash report copied.')));
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
