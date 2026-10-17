import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// The signed-in Firebase user, as much as the app needs.
class AuthUser {
  const AuthUser({required this.uid, this.email, this.usesPassword = true});

  final String uid;
  final String? email;

  /// false for Google-only accounts, which confirm with Google instead.
  final bool usesPassword;
}

/// A sign-in problem worded for players.
class AuthFailure implements Exception {
  const AuthFailure(this.message, {this.code});

  final String message;
  final String? code;

  bool get needsRecentLogin => code == 'requires-recent-login';

  @override
  String toString() => message;
}

/// Sign-in, behind an interface so tests can swap in a fake.
abstract class AuthService {
  AuthUser? get current;
  Stream<AuthUser?> get changes;
  Future<void> signIn(String email, String password);
  Future<void> signUp(String email, String password);
  Future<void> resetPassword(String email);

  /// Whether this build can offer "Continue with Google".
  bool get googleAvailable;

  /// Signs in (or up) with a Google account. Returns false if the player
  /// backed out of the account picker.
  Future<bool> signInWithGoogle();

  /// Confirms who you are again before sensitive actions (account deletion):
  /// with [password] for email accounts, or the Google picker without one.
  Future<void> reauthenticate({String? password});
  Future<void> signOut();
  Future<void> deleteUser();
  Future<String?> idToken({bool refresh = false});
}

class FirebaseAuthService implements AuthService {
  FirebaseAuthService({FirebaseAuth? auth, this.googleClientId = ''})
    : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  /// The project's web OAuth client ID (google-services.json, client_type 3).
  final String googleClientId;
  bool _googleReady = false;

  static AuthUser? _map(User? u) => u == null
      ? null
      : AuthUser(
          uid: u.uid,
          email: u.email,
          usesPassword: u.providerData.any((p) => p.providerId == 'password'),
        );

  @override
  AuthUser? get current => _map(_auth.currentUser);

  @override
  Stream<AuthUser?> get changes => _auth.authStateChanges().map(_map);

  Future<T> _guard<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on FirebaseAuthException catch (e) {
      throw AuthFailure(describeAuthError(e.code), code: e.code);
    }
  }

  @override
  Future<void> signIn(String email, String password) =>
      _guard(() => _auth.signInWithEmailAndPassword(email: email.trim(), password: password));

  @override
  Future<void> signUp(String email, String password) =>
      _guard(() => _auth.createUserWithEmailAndPassword(email: email.trim(), password: password));

  @override
  Future<void> resetPassword(String email) =>
      _guard(() => _auth.sendPasswordResetEmail(email: email.trim()));

  @override
  bool get googleAvailable => googleClientId.isNotEmpty;

  /// Asks Google for an ID token; null if the player backed out.
  Future<OAuthCredential?> _googleCredential() async {
    if (!googleAvailable) throw const AuthFailure('Google sign-in is not set up in this build.');
    final google = GoogleSignIn.instance;
    try {
      if (!_googleReady) {
        await google.initialize(serverClientId: googleClientId);
        _googleReady = true;
      }
      final account = await google.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw const AuthFailure('Google did not confirm the account. Try again.');
      }
      return GoogleAuthProvider.credential(idToken: idToken);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      throw AuthFailure(describeGoogleError(e.code, e.description), code: 'google-${e.code.name}');
    }
  }

  @override
  Future<bool> signInWithGoogle() => _guard(() async {
    final credential = await _googleCredential();
    if (credential == null) return false;
    await _auth.signInWithCredential(credential);
    return true;
  });

  @override
  Future<void> reauthenticate({String? password}) => _guard(() async {
    final user = _auth.currentUser;
    if (user == null) throw const AuthFailure('Not signed in.');
    if (password != null) {
      if (user.email == null) throw const AuthFailure('Not signed in.');
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: user.email!, password: password),
      );
      return;
    }
    final credential = await _googleCredential();
    if (credential == null) {
      throw const AuthFailure('Confirm with Google to continue.', code: 'canceled');
    }
    await user.reauthenticateWithCredential(credential);
  });

  /// Forgets the Google account too, so the picker shows next time.
  Future<void> _googleSignOut() async {
    if (!_googleReady) return;
    try {
      await GoogleSignIn.instance.signOut();
    } on Object {
      // Signing out of Firebase is what matters.
    }
  }

  @override
  Future<void> signOut() async {
    await _googleSignOut();
    await _auth.signOut();
  }

  @override
  Future<void> deleteUser() => _guard(() async {
    await _auth.currentUser?.delete();
    await _googleSignOut();
  });

  @override
  Future<String?> idToken({bool refresh = false}) async => _auth.currentUser?.getIdToken(refresh);
}

/// Used when the build has no Firebase settings: nobody is ever signed in.
class DisabledAuthService implements AuthService {
  const DisabledAuthService();

  static const _off = AuthFailure('Accounts are not available in this build.');

  @override
  AuthUser? get current => null;
  @override
  Stream<AuthUser?> get changes => Stream.value(null);
  @override
  Future<void> signIn(String email, String password) => Future.error(_off);
  @override
  Future<void> signUp(String email, String password) => Future.error(_off);
  @override
  Future<void> resetPassword(String email) => Future.error(_off);
  @override
  bool get googleAvailable => false;
  @override
  Future<bool> signInWithGoogle() => Future.error(_off);
  @override
  Future<void> reauthenticate({String? password}) => Future.error(_off);
  @override
  Future<void> signOut() async {}
  @override
  Future<void> deleteUser() async {}
  @override
  Future<String?> idToken({bool refresh = false}) async => null;
}

String describeAuthError(String code) => switch (code) {
  'invalid-email' => "That email address doesn't look right.",
  'user-disabled' => 'This account has been disabled.',
  'user-not-found' || 'wrong-password' || 'invalid-credential' => 'Wrong email or password.',
  'email-already-in-use' => 'An account with that email already exists. Try signing in.',
  'account-exists-with-different-credential' =>
    'That email already has a password account. Sign in with your password.',
  'user-mismatch' => "That's a different Google account from the one you're signed in with.",
  'weak-password' => 'Choose a longer password (at least 6 characters).',
  'too-many-requests' => 'Too many attempts. Wait a minute and try again.',
  'network-request-failed' => 'No connection. Check your internet and try again.',
  'requires-recent-login' => 'Please confirm your password first.',
  'operation-not-allowed' => 'That way of signing in is not switched on for this game yet.',
  _ => 'Something went wrong signing in ($code).',
};

String describeGoogleError(GoogleSignInExceptionCode code, String? detail) => switch (code) {
  GoogleSignInExceptionCode.clientConfigurationError ||
  GoogleSignInExceptionCode.providerConfigurationError =>
    "Google sign-in isn't set up for this build yet.",
  GoogleSignInExceptionCode.uiUnavailable => "Google sign-in can't open right now. Try again.",
  GoogleSignInExceptionCode.interrupted => 'Google sign-in was interrupted. Try again.',
  _ => 'Google sign-in failed${detail == null || detail.isEmpty ? '' : ' ($detail)'}.',
};
