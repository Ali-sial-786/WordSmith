import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'audio/sfx.dart';
import 'auth/auth_service.dart';
import 'data/campaign.dart';
import 'data/store.dart';
import 'game/account.dart';
import 'game/providers.dart';
import 'net/api_client.dart';
import 'net/config.dart';
import 'net/hub_client.dart';
import 'net/room_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(_bundledLicences);
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final (store, campaign) = await (Store.open(), Campaign.load()).wait;
  final sfx = Sfx(enabled: true, settings: store.loadSettings());
  final auth = await _startAuth();
  final api = AppConfig.hasServer && auth is FirebaseAuthService
      ? ApiClient(baseUrl: AppConfig.apiBase, token: auth.idToken)
      : null;
  final hub = api == null
      ? null
      : HubClient(baseUrl: AppConfig.apiBase, token: auth.idToken);
  runApp(
    ProviderScope(
      overrides: [
        storeProvider.overrideWithValue(store),
        campaignProvider.overrideWithValue(campaign),
        sfxProvider.overrideWithValue(sfx),
        authServiceProvider.overrideWithValue(auth),
        apiClientProvider.overrideWithValue(api),
        hubClientProvider.overrideWithValue(hub),
        roomClientFactoryProvider.overrideWithValue(
          api == null
              ? null
              : (code) => RoomClient(baseUrl: AppConfig.apiBase, code: code, token: auth.idToken),
        ),
      ],
      child: const WordsmithApp(),
    ),
  );
  // Sounds load after the first frame so startup isn't held up.
  sfx.preload().then((_) => sfx.startAmbience());
}

/// Firebase sign-in when this build has its settings; otherwise solo-only.
Future<AuthService> _startAuth() async {
  if (!AppConfig.hasFirebase) return const DisabledAuthService();
  try {
    await Firebase.initializeApp(options: AppConfig.firebaseOptions);
    return FirebaseAuthService(googleClientId: AppConfig.googleWebClientId);
  } on Object catch (e) {
    debugPrint('Firebase unavailable: $e');
    return const DisabledAuthService();
  }
}

/// Licences of bundled fonts and word lists, shown on the licences page
/// alongside the packages' own.
Stream<LicenseEntry> _bundledLicences() async* {
  const files = {
    'SCOWL.txt': ['SCOWL word lists'],
    'Cinzel-OFL.txt': ['Cinzel font'],
    'RobotoSlab-LICENSE.txt': ['Roboto Slab font'],
    'NunitoSans-OFL.txt': ['Nunito Sans font'],
  };
  for (final e in files.entries) {
    final text = await rootBundle.loadString('assets/licenses/${e.key}');
    yield LicenseEntryWithLineBreaks(e.value, text);
  }
}
