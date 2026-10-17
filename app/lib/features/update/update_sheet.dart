import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../update/app_updater.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/metal_button.dart';

/// Downloads Wordsmith [version] from [apk] and installs it, with the
/// download's progress and Android's "install unknown apps" step on the way.
Future<void> showUpdateSheet(BuildContext context, {required String version, required String apk}) =>
    showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Palette.soot,
      builder: (_) => UpdateSheet(version: version, apk: apk),
    );

enum _Step { downloading, allow, installing, failed }

class UpdateSheet extends ConsumerStatefulWidget {
  const UpdateSheet({super.key, required this.version, required this.apk});

  final String version;
  final String apk;

  @override
  ConsumerState<UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends ConsumerState<UpdateSheet> with WidgetsBindingObserver {
  _Step _step = _Step.downloading;
  int _received = 0;
  int _total = -1;
  String? _path;
  String? _error;

  // Kept from the start: the sheet cancels a download on its way out, when
  // ref can no longer be read.
  late final AppUpdater _updater;

  @override
  void initState() {
    super.initState();
    _updater = ref.read(appUpdaterProvider);
    WidgetsBinding.instance.addObserver(this);
    _download();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_step == _Step.downloading) _updater.cancel();
    super.dispose();
  }

  // Back from Android's settings: carry on if installs are allowed now.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _step == _Step.allow) _install();
  }

  Future<void> _download() async {
    setState(() {
      _step = _Step.downloading;
      _received = 0;
      _total = -1;
      _error = null;
    });
    try {
      final path = await _updater.download(
        widget.apk,
        widget.version,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      _path = path;
      await _install();
    } on UpdateFailure catch (e) {
      if (mounted && e.code != 'cancelled') _fail(e.message);
    }
  }

  void _fail(String message) => setState(() {
    _step = _Step.failed;
    _error = message;
  });

  Future<void> _install() async {
    final path = _path;
    if (path == null) return;
    if (!await _updater.canInstall()) {
      if (mounted) setState(() => _step = _Step.allow);
      return;
    }
    final opened = await _updater.install(path);
    if (!mounted) return;
    if (opened) {
      setState(() => _step = _Step.installing);
    } else {
      _fail("Couldn't open Android's installer. Try again.");
    }
  }

  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (title, body) = switch (_step) {
      _Step.downloading => ('Downloading ${widget.version}', _progressLine()),
      _Step.allow => (
        'One more step',
        'Android needs your OK for Wordsmith to install its own updates. '
            'Turn on "Allow from this source", then come back here.',
      ),
      _Step.installing => (
        'Install Wordsmith ${widget.version}',
        "Tap Update on Android's prompt. Your progress stays, and the game opens on the new version.",
      ),
      _Step.failed => ('Update paused', _error ?? ''),
    };
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: displayStyle(24, color: Palette.molten),
            ),
            const SizedBox(height: 10),
            if (_step == _Step.downloading) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: _total > 0 ? _received / _total : null,
                  minHeight: 10,
                  color: Palette.molten,
                  backgroundColor: Palette.ash,
                ),
              ),
              const SizedBox(height: 10),
            ],
            Text(body, textAlign: TextAlign.center, style: text.bodyMedium),
            const SizedBox(height: 18),
            ...switch (_step) {
              _Step.downloading => [TextButton(onPressed: _close, child: const Text('Cancel'))],
              _Step.allow => [
                PlateButton(label: 'Open settings', primary: true, onPressed: _updater.allowInstalls),
                TextButton(onPressed: _close, child: const Text('Later')),
              ],
              _Step.installing => [
                PlateButton(label: 'Install', primary: true, onPressed: _install),
                TextButton(onPressed: _close, child: const Text('Later')),
              ],
              _Step.failed => [
                PlateButton(label: 'Try again', primary: true, onPressed: _download),
                TextButton(onPressed: _close, child: const Text('Close')),
              ],
            },
          ],
        ),
      ),
    );
  }

  String _progressLine() {
    String mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);
    return _total > 0 ? '${mb(_received)} of ${mb(_total)} MB' : '${mb(_received)} MB';
  }
}
