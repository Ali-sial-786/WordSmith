import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../net/config.dart';

/// The pages on the browser version that the app links to.
enum WebPage {
  privacy('/privacy', 'Privacy policy'),
  terms('/terms', 'Terms and chat rules'),
  deleteAccount('/delete-account', 'Delete your account'),
  contact('/contact', 'Contact us'),
  termsFrench('/terms-fr', "Conditions d'utilisation"),
  privacyFrench('/privacy-fr', 'Politique de confidentialité');

  const WebPage(this.path, this.title);
  final String path;
  final String title;

  Uri get uri => Uri.parse('${AppConfig.webBase}$path');
}

/// Opens [page] in the browser; says so if nothing could open it.
Future<void> openWebPage(BuildContext context, WebPage page) => openLink(context, page.uri);

/// Opens [uri] in the browser; says so if nothing could open it.
Future<void> openLink(BuildContext context, Uri uri) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
  } on Object {
    opened = false;
  }
  if (!opened) messenger?.showSnackBar(SnackBar(content: Text("Couldn't open $uri")));
}
