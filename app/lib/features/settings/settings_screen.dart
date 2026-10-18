import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_info.dart';
import '../../auth/auth_service.dart';
import '../../data/diagnostics.dart';
import '../../game/account.dart';
import '../../game/providers.dart';
import '../../net/api_client.dart';
import '../../net/config.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/crash_notice.dart';
import '../../update/app_updater.dart';
import '../account/change_username_screen.dart';
import '../update/update_sheet.dart';
import 'font_picker.dart';
import 'scheme_picker.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: Text('Settings', style: displayStyle(22)), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          _Slider(
            label: 'Sound effects',
            value: s.sfxVolume,
            onChanged: (v) => n.update((s) => s.copyWith(sfxVolume: v)),
          ),
          _Slider(
            label: 'Music',
            value: s.musicVolume,
            onChanged: (v) => n.update((s) => s.copyWith(musicVolume: v)),
          ),
          _Slider(
            label: 'Forge ambience',
            value: s.ambienceVolume,
            onChanged: (v) => n.update((s) => s.copyWith(ambienceVolume: v)),
          ),
          // iPhones have no web vibration.
          if (!kIsWeb)
            SwitchListTile(
              title: const Text('Vibration'),
              value: s.haptics,
              onChanged: (v) => n.update((s) => s.copyWith(haptics: v)),
            ),
          const _Appearance(),
          SwitchListTile(
            title: const Text('Left-handed layout'),
            subtitle: const Text('Hint buttons on the left of the anvil'),
            value: s.leftHanded,
            onChanged: (v) => n.update((s) => s.copyWith(leftHanded: v)),
          ),
          SwitchListTile(
            title: const Text('Reduce motion'),
            subtitle: const Text('Fewer sparks and drifting embers'),
            value: s.reducedMotion,
            onChanged: (v) => n.update((s) => s.copyWith(reducedMotion: v)),
          ),
          if (ref.watch(accountProvider).phase != AccountPhase.unavailable)
            SwitchListTile(
              title: const Text('Video chat in Co-op and Versus'),
              subtitle: const Text(
                'Friends in your room see you in a small bubble, and you hear each other. '
                'Uses more data, so Wi-Fi is best.',
              ),
              value: s.videoChat,
              onChanged: (v) => n.update((s) => s.copyWith(videoChat: v)),
            ),
          if (ref.watch(accountProvider).isReady && !kIsWeb)
            SwitchListTile(
              title: const Text('Notifications'),
              subtitle: const Text('Room invites and gifts from friends, and your daily reminder'),
              value: s.inviteNotifications,
              onChanged: (v) => ref.read(accountProvider.notifier).setInviteNotifications(v),
            ),
          if (ref.watch(accountProvider).isReady && !kIsWeb)
            SwitchListTile(
              title: const Text('Daily reminder'),
              subtitle: Text(
                s.reminderHour == null
                    ? "A nudge when today's commission is still waiting"
                    : 'At ${_hourLabel(context, s.reminderHour!)}, if the commission is still waiting. Tap to change.',
              ),
              value: s.inviteNotifications && s.reminderHour != null,
              onChanged: s.inviteNotifications
                  ? (on) => _pickReminder(context, ref, on ? (s.reminderHour ?? 19) : null)
                  : null,
            ),
          const _AccountSection(),
          const _Troubleshooting(),
          const Divider(height: 32),
          ListTile(
            title: const Text('Credits'),
            subtitle: const Text('Fonts, sounds, icons and word lists'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/credits'),
          ),
          const _VersionTile(),
        ],
      ),
    );
  }
}

/// Compatibility graphics and the last crash report, when there's something
/// to show (Android only).
class _Troubleshooting extends ConsumerWidget {
  const _Troubleshooting();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final graphics = ref.watch(graphicsProvider).value;
    final crash = ref.watch(lastCrashProvider).value;
    if (graphics == null && crash == null) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Troubleshooting', style: text.titleSmall?.copyWith(color: Palette.steel)),
        ),
        if (graphics != null)
          SwitchListTile(
            title: const Text('Compatibility graphics'),
            subtitle: Text(
              [
                'Try this if the game crashes or flickers.',
                if (graphics.auto) 'Turned on after a crash.',
                if (graphics.compat != (graphics.active == 'opengles')) 'Takes effect next time you open the game.',
              ].join(' '),
            ),
            value: graphics.compat,
            onChanged: (on) async {
              await ref.read(diagnosticsProvider).setCompat(on);
              ref.invalidate(graphicsProvider);
            },
          ),
        if (crash != null)
          ListTile(
            title: const Text('Copy crash report'),
            subtitle: Text('${crash.title}, ${MaterialLocalizations.of(context).formatMediumDate(crash.at.toLocal())}'),
            trailing: const Icon(Icons.copy),
            onTap: () async {
              await copyCrashReport(ref, crash);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Crash report copied.')));
              }
            },
          ),
      ],
    );
  }
}

/// The colour scheme and fonts.
class _Appearance extends StatelessWidget {
  const _Appearance();

  @override
  Widget build(BuildContext context) =>
      const Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [SchemePicker(), FontPicker()]);
}

/// The version, and in the Android app a check for a newer one, which it
/// can download and install.
class _VersionTile extends ConsumerStatefulWidget {
  const _VersionTile();

  @override
  ConsumerState<_VersionTile> createState() => _VersionTileState();
}

class _VersionTileState extends ConsumerState<_VersionTile> {
  bool _checking = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    ref.invalidate(serverVersionProvider);
    final v = await ref.read(serverVersionProvider.future);
    if (!mounted) return;
    setState(() => _checking = false);
    final apk = v?.apk;
    if (v != null && apk != null && compareVersions(v.latest, appVersion) > 0) {
      await showUpdateSheet(context, version: v.latest, apk: apk);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(v == null ? "Couldn't reach the forge. Check your connection." : 'You have the latest version.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final version = Text(appVersion, style: text.bodyMedium);
    if (!ref.watch(appUpdaterProvider).supported || !AppConfig.hasServer) {
      return ListTile(title: const Text('Version'), trailing: version);
    }
    final v = ref.watch(serverVersionProvider).value;
    final newer = v != null && v.apk != null && compareVersions(v.latest, appVersion) > 0;
    return ListTile(
      title: const Text('Version'),
      subtitle: Text(newer ? 'Wordsmith ${v.latest} is out. Tap to update.' : 'Tap to check for updates'),
      trailing: _checking
          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : version,
      onTap: _checking ? null : _check,
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider({required this.label, required this.value, required this.onChanged});

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(label),
    subtitle: Slider(value: value, onChanged: onChanged),
  );
}

class _AccountSection extends ConsumerWidget {
  const _AccountSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final n = ref.read(accountProvider.notifier);
    if (account.phase == AccountPhase.unavailable) return const SizedBox.shrink();
    final signedIn = account.user != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Account', style: Theme.of(context).textTheme.titleMedium),
        ),
        if (!signedIn)
          ListTile(
            title: const Text('Sign in'),
            subtitle: const Text('Keep your progress safe and play with friends'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/sign-in'),
          )
        else ...[
          ListTile(
            title: Text(account.server?.username ?? 'Signed in'),
            subtitle: Text(account.user?.email ?? ''),
            trailing: account.syncing
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(tooltip: 'Sync now', icon: const Icon(Icons.sync), onPressed: n.sync),
          ),
          if (account.isReady)
            ListTile(
              title: const Text('Change username'),
              subtitle: Text(
                account.server!.usernameLocked
                    ? 'You can change it again on ${nextChangeLabel(context, account.server!.nextUsernameChangeAt!)}'
                    : 'Pick a new smith name (once a week)',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ChangeUsernameScreen())),
            ),
          ListTile(title: const Text('Sign out'), onTap: n.signOut),
          ListTile(
            title: Text('Delete account', style: TextStyle(color: Palette.quenchRed)),
            subtitle: const Text('Removes your account, progress and friends for good'),
            onTap: () => showDialog<void>(context: context, builder: (_) => const _DeleteDialog()),
          ),
        ],
      ],
    );
  }
}

class _DeleteDialog extends ConsumerStatefulWidget {
  const _DeleteDialog();

  @override
  ConsumerState<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends ConsumerState<_DeleteDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final google = !(ref.read(accountProvider).user?.usesPassword ?? true);
      await ref.read(accountProvider.notifier).deleteAccount(password: google ? null : _password.text);
      if (mounted) Navigator.of(context).pop();
    } on AuthFailure catch (e) {
      setState(() => _error = e.message);
    } on ApiException catch (e) {
      setState(() => _error = e.friendly);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final google = !(ref.watch(accountProvider).user?.usesPassword ?? true);
    return AlertDialog(
      title: const Text('Delete your account?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Your smith, progress, hints and friends will be deleted on the '
            'server and on this phone. This can\'t be undone.',
          ),
          const SizedBox(height: 14),
          if (google)
            const Text('Google will ask you to confirm your account.')
          else
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm your password'),
            ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: Palette.quenchRed)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Keep it')),
        TextButton(
          onPressed: _busy ? null : _delete,
          child: Text('Delete', style: TextStyle(color: Palette.quenchRed)),
        ),
      ],
    );
  }
}

String _hourLabel(BuildContext context, int hour) =>
    MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay(hour: hour, minute: 0));

/// Turns the Daily Commission reminder off ([hour] null) or asks for its hour.
Future<void> _pickReminder(BuildContext context, WidgetRef ref, int? hour) async {
  int? chosen = hour;
  if (hour != null) {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: hour, minute: 0),
      helpText: 'Remind me at (the hour counts)',
    );
    if (picked == null) return;
    chosen = picked.hour;
  }
  try {
    await ref.read(accountProvider.notifier).setDailyReminder(chosen);
  } on ApiException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.friendly)));
  }
}
