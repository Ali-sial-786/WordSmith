import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_info.dart';
import '../../ui/theme/theme.dart';

/// Third-party credits, generated into assets/credits.json from
/// art/CREDITS.md, plus the word lists.
class CreditsScreen extends StatelessWidget {
  const CreditsScreen({super.key});

  static const _wordLists = [
    (
      'SCOWL word lists',
      'Kevin Atkinson and contributors',
      'SCOWL licence (copyright notice)',
      'http://wordlist.aspell.net/',
    ),
    ('ENABLE word list', 'Alan Beale and M. Cooper', 'Public domain', ''),
    (
      'List of Dirty, Naughty, Obscene and Otherwise Bad Words',
      'Shutterstock and contributors',
      'CC BY 4.0',
      'https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words',
    ),
  ];

  Future<List<Map<String, dynamic>>> _load() async {
    try {
      final raw = await rootBundle.loadString('assets/credits.json');
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } on Object {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text('Credits', style: displayStyle(22)), centerTitle: true),
      body: FutureBuilder(
        future: _load(),
        builder: (context, snap) {
          final assets = snap.data ?? const [];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Wordsmith is made with free, openly licensed fonts, sounds, '
                'icons and word lists. Thank you to their creators.\n\n'
                'Icons by Lorc, Delapouite, Carl Olsen and Kier Heyl from '
                'game-icons.net, CC BY 3.0. Sound effects include CC0 packs by '
                'Kenney (kenney.nl) and PagDev.',
                style: text.bodyMedium,
              ),
              const SizedBox(height: 16),
              Text('Word lists', style: text.titleMedium),
              for (final (title, author, licence, url) in _wordLists)
                _Entry(title: title, author: author, licence: licence, url: url),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'Wordsmith',
                  applicationVersion: appVersion,
                ),
                child: const Text('Full licence texts'),
              ),
              const SizedBox(height: 16),
              Text('Art, sound and fonts', style: text.titleMedium),
              for (final a in assets)
                _Entry(
                  title: '${a['title'] ?? a['file']}',
                  author: '${a['author'] ?? ''}',
                  licence: '${a['licence'] ?? ''}',
                  url: '${a['url'] ?? ''}',
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({
    required this.title,
    required this.author,
    required this.licence,
    required this.url,
  });

  final String title;
  final String author;
  final String licence;
  final String url;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text([author, licence, url].where((s) => s.isNotEmpty).join(' · ')),
  );
}
