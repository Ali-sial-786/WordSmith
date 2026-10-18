import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../game/account.dart';
import '../../net/api_client.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/metal_button.dart';

final _validName = RegExp(r'^[A-Za-z0-9_]{3,16}$');

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// First-time setup: pick a smith name (it can change later in Settings),
/// an emblem, and say when you were born (shared/age.md). An account made
/// before ages were asked comes here once for the birth month and year only.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _name = TextEditingController();
  String _avatar = avatarIds.first;
  int? _birthMonth;
  int? _birthYear;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Only the age is missing: the account already has its name.
  bool get _ageOnly => ref.read(accountProvider).server?.needsSetup == false;

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (!_ageOnly && !_validName.hasMatch(name)) {
      setState(() => _error = 'Use 3–16 letters, numbers or _.');
      return;
    }
    final (year, month) = (_birthYear, _birthMonth);
    if (year == null || month == null) {
      setState(() => _error = 'Choose the month and year you were born.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final account = ref.read(accountProvider.notifier);
    try {
      if (_ageOnly) {
        await account.confirmAge(birthYear: year, birthMonth: month);
      } else {
        await account.setup(name, _avatar, birthYear: year, birthMonth: month);
      }
      if (mounted) context.go('/');
    } on ApiException catch (e) {
      if (e.code == 'under_13') {
        if (mounted) await _tooYoung();
        return;
      }
      if (mounted) setState(() => _error = e.friendly);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Online play closed on this phone (the account is already gone).
  Future<void> _tooYoung() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Online play is for 13 and over'),
        content: const Text(
          "Your account has been removed, so friends and rooms aren't available on this phone. "
          'Solo play and your progress on this phone are still yours.',
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
      ),
    );
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ageOnly = _ageOnly;
    return Scaffold(
      appBar: AppBar(
        title: Text(ageOnly ? 'One more thing' : 'Your smith', style: displayStyle(22)),
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (!ageOnly) ..._nameAndEmblem(text),
          Text('When were you born?', style: text.titleMedium),
          const SizedBox(height: 6),
          Text(
            ageOnly
                ? 'Online play now asks everyone once. Just the month and year: it keeps the forge right for your age.'
                : 'Just the month and year: it keeps the forge right for your age. Other smiths never see it.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 12),
          _BirthPicker(
            month: _birthMonth,
            year: _birthYear,
            onMonth: (m) => setState(() {
              _birthMonth = m;
              _error = null;
            }),
            onYear: (y) => setState(() {
              _birthYear = y;
              _error = null;
            }),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: text.bodyMedium?.copyWith(color: Palette.quenchRed)),
          ],
          const SizedBox(height: 22),
          PlateButton(
            label: _busy ? 'Forging…' : (ageOnly ? 'Continue' : 'Start forging'),
            primary: true,
            onPressed: _busy ? null : _submit,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy
                ? null
                : () => ref.read(accountProvider.notifier).signOut().then((_) {
                    if (context.mounted) context.go('/');
                  }),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }

  List<Widget> _nameAndEmblem(TextTheme text) => [
    Text('Pick a name', style: text.titleMedium),
    const SizedBox(height: 6),
    Text('Friends find you by it. You can change it later in Settings.', style: text.bodySmall),
    const SizedBox(height: 10),
    TextField(
      controller: _name,
      maxLength: 16,
      style: fieldText(),
      decoration: const InputDecoration(labelText: 'Smith name', helperText: '3–16 letters, numbers or _'),
      onChanged: (_) => setState(() => _error = null),
    ),
    const SizedBox(height: 16),
    Text('Pick an emblem', style: text.titleMedium),
    const SizedBox(height: 12),
    GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 14,
      crossAxisSpacing: 14,
      children: [
        for (final id in avatarIds)
          GestureDetector(
            onTap: () => setState(() => _avatar = id),
            child: AvatarBadge(avatar: id, size: 64, selected: id == _avatar),
          ),
      ],
    ),
    const SizedBox(height: 24),
  ];
}

/// Month and year dropdowns, both empty to start: nothing suggests an answer.
class _BirthPicker extends StatelessWidget {
  const _BirthPicker({required this.month, required this.year, required this.onMonth, required this.onYear});

  final int? month;
  final int? year;
  final ValueChanged<int?> onMonth;
  final ValueChanged<int?> onYear;

  @override
  Widget build(BuildContext context) {
    final thisYear = DateTime.now().toUtc().year;
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: DropdownButtonFormField<int>(
            initialValue: month,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Month'),
            style: fieldText(),
            items: [for (final (i, name) in _months.indexed) DropdownMenuItem(value: i + 1, child: Text(name))],
            onChanged: onMonth,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: DropdownButtonFormField<int>(
            initialValue: year,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Year'),
            style: fieldText(),
            menuMaxHeight: 320,
            items: [for (var y = thisYear; y >= thisYear - 100; y--) DropdownMenuItem(value: y, child: Text('$y'))],
            onChanged: onYear,
          ),
        ),
      ],
    );
  }
}
