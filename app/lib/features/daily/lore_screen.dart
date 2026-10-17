import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/sfx.dart';
import '../../data/lore.dart';
import '../../game/account.dart';
import '../../game/providers.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/game_icon.dart';

/// Smith's Lore: one page of forge history per Daily Commission forged.
class LoreScreen extends ConsumerWidget {
  const LoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pages = ref.watch(loreProvider).value ?? const <LorePage>[];
    final total = ref.watch(dailyProvider).value?.total ?? 0;
    final unlocked = total.clamp(0, pages.length);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, title: Text("Smith's Lore", style: displayStyle(22))),
      extendBodyBehindAppBar: true,
      body: ForgeBackground(
        image: 'assets/images/bg_hall.webp',
        dim: 0.72,
        fire: 0.5,
        child: SafeArea(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: pages.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    pages.isEmpty
                        ? 'The Lore Book is empty for now.'
                        : 'Every Daily Commission you forge adds a page. '
                              '$unlocked of ${pages.length} pages found.',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(color: Palette.steel),
                  ),
                );
              }
              final index = i - 1;
              final page = pages[index];
              final open = index < unlocked;
              return Card(
                color: open ? const Color(0xFF2E241B) : Palette.soot.withValues(alpha: 0.7),
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: GameIcon(open ? 'book' : 'lock', size: 24, color: open ? Palette.molten : Palette.ash),
                  title: Text(
                    open ? page.title : 'Page ${index + 1}',
                    style: text.titleSmall?.copyWith(color: open ? null : Palette.steel),
                  ),
                  subtitle: Text(
                    open
                        ? page.topicLabel
                        : index == unlocked
                        ? 'Forge your next Daily Commission to read it'
                        : 'Forge ${index - unlocked + 1} more Daily Commissions',
                    style: text.labelSmall,
                  ),
                  onTap: open ? () => _openPage(context, ref, pages.sublist(0, unlocked), index) : null,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _openPage(BuildContext context, WidgetRef ref, List<LorePage> pages, int start) {
    final sfx = ref.read(sfxProvider)..play(SfxId.page);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2E241B),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.5,
        child: PageView.builder(
          controller: PageController(initialPage: start),
          itemCount: pages.length,
          onPageChanged: (_) => sfx.play(SfxId.page),
          itemBuilder: (context, i) => LorePageView(page: pages[i], number: i + 1),
        ),
      ),
    );
  }
}

/// One page, as on parchment.
class LorePageView extends StatelessWidget {
  const LorePageView({super.key, required this.page, required this.number});

  final LorePage page;
  final int number;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Page $number · ${page.topicLabel}', style: text.labelMedium?.copyWith(color: Palette.molten)),
          const SizedBox(height: 6),
          Text(page.title, style: displayStyle(24)),
          const SizedBox(height: 12),
          Text(page.text, style: text.bodyLarge?.copyWith(height: 1.45)),
        ],
      ),
    );
  }
}
