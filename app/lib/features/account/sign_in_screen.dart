import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../auth/auth_service.dart';
import '../../game/account.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/metal_button.dart';

/// Email or Google sign-in and sign-up.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _create = false;
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (!email.contains('@')) {
      setState(() => _error = "That email address doesn't look right.");
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'Passwords are at least 6 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final account = ref.read(accountProvider.notifier);
    try {
      _create ? await account.signUp(email, password) : await account.signIn(email, password);
    } on AuthFailure catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _google() async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await ref.read(accountProvider.notifier).signInWithGoogle();
    } on AuthFailure catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgot() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Type your email above first.');
      return;
    }
    try {
      await ref.read(accountProvider.notifier).resetPassword(email);
      setState(() {
        _error = null;
        _info = 'Check $email for a link to reset your password.';
      });
    } on AuthFailure catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(accountProvider, (_, next) {
      if (next.phase == AccountPhase.needsSetup) context.pushReplacement('/setup');
      if (next.phase == AccountPhase.ready && context.canPop()) context.pop();
    });
    final text = Theme.of(context).textTheme;
    final google = ref.read(accountProvider.notifier).googleAvailable;
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent),
      extendBodyBehindAppBar: true,
      body: ForgeBackground(
        image: 'assets/images/bg_hall.webp',
        fire: 0.6,
        dim: 0.7,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: ListView(
                padding: const EdgeInsets.all(24),
                shrinkWrap: true,
                children: [
                  Text(
                    _create ? 'Join the Guild' : 'Welcome back',
                    textAlign: TextAlign.center,
                    style: displayStyle(28, color: Palette.molten),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Sign in to keep your progress safe and play with friends.',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(color: Palette.steel),
                  ),
                  const SizedBox(height: 24),
                  if (google) ...[
                    _GoogleButton(onPressed: _busy ? null : _google),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(child: Divider(color: Palette.ash)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text('or use email', style: text.labelMedium?.copyWith(color: Palette.steel)),
                        ),
                        Expanded(child: Divider(color: Palette.ash)),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: [_create ? AutofillHints.newPassword : AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: 'Password',
                      helperText: _create ? 'At least 6 characters' : null,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: text.bodyMedium?.copyWith(color: Palette.quenchRed)),
                  ],
                  if (_info != null) ...[
                    const SizedBox(height: 12),
                    Text(_info!, style: text.bodyMedium?.copyWith(color: Palette.verdigris)),
                  ],
                  const SizedBox(height: 20),
                  PlateButton(
                    label: _busy ? 'Working…' : (_create ? 'Create account' : 'Sign in'),
                    primary: true,
                    onPressed: _busy ? null : _submit,
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _create = !_create;
                            _error = null;
                          }),
                    child: Text(_create ? 'Already have an account? Sign in' : 'New here? Create an account'),
                  ),
                  if (!_create) TextButton(onPressed: _busy ? null : _forgot, child: const Text('Forgot password?')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Google's standard light sign-in button.
class _GoogleButton extends StatelessWidget {
  const _GoogleButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1F1F1F),
        disabledBackgroundColor: Colors.white70,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      onPressed: onPressed,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SvgPicture.asset('assets/icons/google_g.svg', width: 20, height: 20),
          const SizedBox(width: 12),
          const Flexible(
            child: Text(
              'Continue with Google',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    ),
  );
}
