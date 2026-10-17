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
