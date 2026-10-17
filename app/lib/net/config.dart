import 'package:firebase_core/firebase_core.dart';

/// Build-time settings, passed with `--dart-define` or
/// `--dart-define-from-file=dart_defines.json` (git-ignored). Without them
/// the app runs solo-only.
abstract final class AppConfig {
  /// Worker base URL. Public; override with `--dart-define=API_BASE=…`.
  static const apiBase = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'https://wordsmith-api.wordsmith-forge.workers.dev',
  );

  /// Firebase web API key for the Android app. Not a secret (it ships in
  /// every APK), but kept out of the public repo to avoid secret-scanning
  /// alarms.
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');

  /// The project's web OAuth client ID ("client_type": 3 in
  /// google-services.json), needed for "Continue with Google". Public.
  static const googleWebClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue: '920525083065-gslh1nvo2evhb6j0oj8v3m6tkc28ahb7.apps.googleusercontent.com',
  );

  static bool get hasFirebase => firebaseApiKey.isNotEmpty;
  static bool get hasServer => apiBase.isNotEmpty;

  /// Accounts need both sign-in and the server.
  static bool get onlineEnabled => hasFirebase && hasServer;

  /// From the project's google-services.json (project wordsmith-8f550).
  static FirebaseOptions get firebaseOptions => const FirebaseOptions(
    apiKey: firebaseApiKey,
    appId: '1:920525083065:android:64d3e8d63203074d96e668',
    messagingSenderId: '920525083065',
    projectId: 'wordsmith-8f550',
    storageBucket: 'wordsmith-8f550.firebasestorage.app',
  );
}
