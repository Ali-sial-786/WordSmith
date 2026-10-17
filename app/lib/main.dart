import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'audio/sfx.dart';
import 'data/campaign.dart';
import 'data/store.dart';
import 'game/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(_bundledLicences);
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final (store, campaign) = await (Store.open(), Campaign.load()).wait;
  final sfx = Sfx(enabled: true, settings: store.loadSettings());
  runApp(
    ProviderScope(
      overrides: [
        storeProvider.overrideWithValue(store),
        campaignProvider.overrideWithValue(campaign),
        sfxProvider.overrideWithValue(sfx),
      ],
      child: const WordsmithApp(),
    ),
  );
  // Sounds load after the first frame so startup isn't held up.
  sfx.preload().then((_) => sfx.startAmbience());
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
