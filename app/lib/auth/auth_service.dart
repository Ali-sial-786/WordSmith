import 'package:firebase_auth/firebase_auth.dart';

/// The signed-in Firebase user, as much as the app needs.
class AuthUser {
  const AuthUser({required this.uid, this.email});

  final String uid;
  final String? email;
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

  /// Confirms the password again before sensitive actions (account deletion).
  Future<void> reauthenticate(String password);
  Future<void> signOut();
  Future<void> deleteUser();
  Future<String?> idToken({bool refresh = false});
}

class FirebaseAuthService implements AuthService {
  FirebaseAuthService([FirebaseAuth? auth]) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  static AuthUser? _map(User? u) =>
      u == null ? null : AuthUser(uid: u.uid, email: u.email);

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
  Future<void> signIn(String email, String password) => _guard(
    () => _auth.signInWithEmailAndPassword(email: email.trim(), password: password),
  );

  @override
  Future<void> signUp(String email, String password) => _guard(
    () => _auth.createUserWithEmailAndPassword(email: email.trim(), password: password),
  );

  @override
  Future<void> resetPassword(String email) =>
      _guard(() => _auth.sendPasswordResetEmail(email: email.trim()));

  @override
  Future<void> reauthenticate(String password) => _guard(() async {
    final user = _auth.currentUser;
    if (user?.email == null) throw const AuthFailure('Not signed in.');
    await user!.reauthenticateWithCredential(
      EmailAuthProvider.credential(email: user.email!, password: password),
    );
  });

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Future<void> deleteUser() => _guard(() async => _auth.currentUser?.delete());

  @override
  Future<String?> idToken({bool refresh = false}) async =>
      _auth.currentUser?.getIdToken(refresh);
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
  Future<void> reauthenticate(String password) => Future.error(_off);
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
  'user-not-found' || 'wrong-password' || 'invalid-credential' =>
    'Wrong email or password.',
  'email-already-in-use' => 'An account with that email already exists. Try signing in.',
  'weak-password' => 'Choose a longer password (at least 6 characters).',
  'too-many-requests' => 'Too many attempts. Wait a minute and try again.',
  'network-request-failed' => 'No connection. Check your internet and try again.',
  'requires-recent-login' => 'Please confirm your password first.',
  'operation-not-allowed' => 'Email sign-in is not switched on for this game yet.',
  _ => 'Something went wrong signing in ($code).',
};
