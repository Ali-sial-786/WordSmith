import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../game/account.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_frame.dart';
import '../settings/settings_screen.dart' show DeleteAccountDialog;

/// `#/delete-account`: deleting an account from the browser version, where
/// the `/delete-account` page sends people (and app stores ask for a web
/// way to do it). Sign in, then confirm. The app has the same in Settings.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  /// The account was deleted on this screen.
  bool _deleted = false;

  Future<void> _delete() async {
    await showDialog<void>(context: context, builder: (_) => const DeleteAccountDialog());
    if (mounted && ref.read(accountProvider).phase == AccountPhase.signedOut) setState(() => _deleted = true);
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(accountProvider);
    final text = Theme.of(context).textTheme;
    final signedIn =
        account.isReady || account.phase == AccountPhase.needsSetup || account.phase == AccountPhase.notOffered;
    final Widget body;
    if (_deleted) {
      body = Column(
        children: [
          Icon(Icons.check_circle_outline, size: 56, color: Palette.verdigris),
          const SizedBox(height: 12),
          Text('Your account has been deleted.', textAlign: TextAlign.center, style: text.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Your smith, progress, friends and everything else on the server are gone.',
            textAlign: TextAlign.center,
            style: text.bodyMedium,
          ),
          const SizedBox(height: 20),
          OutlinedButton(onPressed: () => context.go('/'), child: const Text('Back to the game')),
        ],
      );
    } else if (account.phase == AccountPhase.unavailable) {
      body = Text(
        "Accounts aren't available in this version of the game.",
        textAlign: TextAlign.center,
        style: text.bodyMedium,
      );
    } else if (account.phase == AccountPhase.loading) {
      body = Center(child: CircularProgressIndicator(color: Palette.molten));
    } else if (!signedIn) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Sign in with the account you want to delete: the same Google account, or email and password, '
            'that you use in the game.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => context.push('/sign-in'), child: const Text('Sign in')),
        ],
      );
    } else {
      final name = account.server?.username;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            name == null ? 'Signed in as ${account.user?.email ?? 'you'}.' : 'Signed in as $name.',
            style: text.titleMedium,
          ),
          if (name != null && account.user?.email != null) Text(account.user!.email!, style: text.bodySmall),
          const SizedBox(height: 14),
          Text(
            'Deleting your account removes your smith, level, XP and hints, campaign and Daily Commission '
            'progress, stats, friends and nicknames, blocks and reports, and your sign-in. Co-op and Versus '
            "results stay for the other players, with you removed from them. It can't be undone.",
            style: text.bodyMedium,
          ),
          const SizedBox(height: 18),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Palette.quenchRed, foregroundColor: Colors.white),
            onPressed: _delete,
            child: const Text('Delete my account'),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: () => context.go('/'), child: const Text('Keep my account')),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text('Delete your account', style: displayStyle(20)), centerTitle: true),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(20),
            children: [ForgePanel(padding: const EdgeInsets.all(18), child: body)],
          ),
        ),
      ),
    );
  }
}
