import 'package:flutter/material.dart';

import '../../engine/hints.dart';
import '../../engine/masterworks.dart';
import '../../engine/progression.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_frame.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/rank_badge.dart';
import '../daily/calendar_screen.dart' show bronzeDays, silverDays;

/// The Hall's "?": a small forged plate that opens the guide.
class HelpButton extends StatelessWidget {
  const HelpButton({super.key, this.size = 46});

  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'How to play',
    child: Semantics(
      button: true,
      label: 'Help',
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: ForgeFrame(
          kind: ForgeFrameKind.plate,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () => showHelpSheet(context),
              borderRadius: BorderRadius.circular(ForgeFrameKind.plate.radius),
              child: Center(
                child: Text('?', style: displayStyle(size * 0.5, color: Palette.molten).copyWith(height: 1)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Explains every mode and button the player can reach, in plain words.
Future<void> showHelpSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  backgroundColor: Palette.soot,
  builder: (_) => const HelpSheet(),
);

class HelpSheet extends StatelessWidget {
  const HelpSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final sections = _sections();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      maxChildSize: 0.92,
      minChildSize: 0.4,
      builder: (context, controller) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("The Smith's Guide", style: displayStyle(24, color: Palette.molten)),
                      Text('What every mode and button does', style: text.bodyMedium?.copyWith(color: Palette.steel)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close, color: Palette.steel),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: Palette.ash),
          Expanded(
            child: ListView.builder(
              controller: controller,
              padding: EdgeInsets.fromLTRB(14, 6, 14, 24 + MediaQuery.paddingOf(context).bottom),
              itemCount: sections.length,
              itemBuilder: (context, i) => _SectionView(section: sections[i]),
            ),
          ),
        ],
      ),
    );
  }
}

/// One heading in the guide and what sits under it.
class _Section {
  const _Section(this.title, this.entries, {this.intro, this.signIn = false});

  final String title;

  /// A line before the entries, for what they share.
  final String? intro;
  final List<_Entry> entries;

  /// All of it needs an account.
  final bool signIn;
}

/// One mode, screen or tool.
class _Entry {
  const _Entry(this.icon, this.title, this.body, {this.signIn = false, this.extra});

  /// A [GameIcon], the same one its button shows where it has one.
  final String icon;
  final String title;

  /// Plain words; **stars** pick out names to look for.
  final String body;

  /// It needs an account.
  final bool signIn;

  /// Shown under [body].
  final Widget? extra;
}

List<_Section> _sections() => [
  const _Section('Play on your own', [
    _Entry(
      'anvil',
      'Forge (Solo play)',
      'The campaign: just you and the anvil. Swipe across the letters to forge words and fill the mold. '
          'Nine chapters, one for each metal, run from **Tin** to **Starmetal**, each a little hotter than '
          'the last. Finish them all and the **Master Forge** brings every puzzle round again, at full XP. '
          'It works offline too.',
    ),
    _Entry(
      'flame',
      'Daily Commission',
      'A new puzzle every day, the same for every smith. Forge it on days in a row to build a **streak**, '
          'and each day of it pays a little more XP, for up to a week. Missed a day? Play it late from the '
          '**calendar** (this month or last) for XP and a Lore page, though not the streak. Forge $bronzeDays '
          'days in a month for a **bronze** trophy, $silverDays for **silver**, every day for **gold**.',
      signIn: true,
    ),
    _Entry(
      'ember',
      'The Crucible',
      'Solo **Survival**. One word at a time glows hot, with a countdown: forge it in time, or it '
          '**melts** and your run is over. Other words can be forged whenever you like, and their letters '
          'help with the hot one. Puzzles keep coming, bigger each time, until something melts. Hints work '
          "here; embers, gilded cells and the Scrap Bin don't.",
    ),
    _Entry(
      'map',
      'Chapters',
      "All nine metals, and how far you've got in each. Open a chapter to replay any puzzle you've "
          'already forged, just for practice (no hints, no XP).',
    ),
  ]),
  const _Section(
    'Play with friends',
    signIn: true,
    intro:
        'Tap **Co-op** or **Versus** and light a forge to host: you get a 6-letter room code to share, or '
        "invite friends straight in. To join, type a friend's code or tap their open room. In a room you "
        'can send quick emotes, and turn on video chat in Settings.',
    [
      _Entry(
        'tongs',
        'Co-op: The Guild Forge',
        'Up to 4 smiths share one mold and one timer. Whoever forges a word first scores it, and it fills '
            'in their colour. Fill the mold before time runs out to win together; the top scorer is '
            "**Master of the Forge**. Hints come from your own stock, and letters they reveal score nothing. "
            "The host's level sets the heat.\n\n"
            '**Survival:** the host can pick it in the lobby. The team shares one hot word, and if it melts '
            'the round is over.',
      ),
      _Entry(
        'trophy',
        'Versus: Anvil Clash',
        'Up to 5 smiths race the same puzzle, each on their own mold, so nobody can take your words. The '
            'first to fill their mold wins the round; if time runs out, the most letters filled wins. Play a '
            'best of 3, 5, 7 or 10. No hints in a clash, but Turn is fine.\n\n'
            '**Survival clash:** the host can pick it in the lobby. Each smith gets their own hot word with a '
            'countdown. The first word to melt ends the round for everyone, and the smith who let it melt '
            "can't win that round.",
      ),
      _Entry(
        'friends',
        'Friends',
        "Add friends by their smith name. See who's online, forging solo or in a room, and tap **Join** to "
            'hop into their room. The **Leaderboard** tab ranks you and your friends by XP. Room invites '
            'from friends pop up in the Forge Hall.',
      ),
    ],
  ),
  const _Section(
    'Forge Board',
    signIn: true,
    intro:
        'Tap **Forge Board** for daily goals and friendly contests. A red badge on it means rewards are '
        'waiting for you to claim.',
    [
      _Entry(
        'bellows',
        'Daily Stoke',
        'Stoke the forge once a day for a reward on a 7-day track: XP and hints, with a Spark Shower on '
            'day 7. Missing a day never resets it.',
      ),
      _Entry(
        'scroll',
        'Work Orders',
        'Three small jobs each day, like forging 30 words. Each pays XP and a Hammer Strike, and filling '
            "all three opens the **Smith's Ledger** chest. Don't fancy one? Swap it, once a day. Two weekly "
            'orders, one of them a **Letter Hunt**, pay even more.',
      ),
      _Entry(
        'trophy',
        'Weekly Trials',
        'A week-long XP race between you and your friends, and XP from anywhere counts. The top three win '
            'prizes, which you claim the week after.',
      ),
      _Entry(
        'gift',
        'Gifts',
        'Send each friend a free Hammer Strike every day. It costs you nothing. Gifts from friends wait '
            'here for you to collect.',
      ),
    ],
  ),
  _Section('Your smith', [
    const _Entry(
      'user',
      'Profile and ranks',
      'Every mode earns XP, and XP raises your **Smith Level**. Each level gives you a Hammer Strike, with '
          'extra hints every 5th and 10th level and at each new rank. Tap **Profile**, or your card at the '
          'top of the Hall, to see your hints and records.',
      extra: _RankLadder(),
    ),
    _Entry(
      'blueprint',
      'Armory and Masterworks',
      'Some campaign puzzles hide a **gilded cell** with a gold edge. Forge the word through it for a '
          '**blueprint piece**. Pieces build ${masterworkSpecs.length} legendary **Masterworks**, one after '
          'another. Each one you finish pays $masterworkXp XP, a Chisel and a Spark Shower, and hangs in the '
          '**Armory**. Open it from your Profile.',
    ),
    const _Entry(
      'book',
      'Lore Book',
      "Every Daily Commission you forge adds a page of **Smith's Lore**: true tales of metals, words and "
          'legends of the forge. Read them from your Profile or the Daily Commission screen.',
    ),
    const _Entry(
      'settings',
      'Settings',
      'Sound, music and forge ambience, vibration, colours and fonts, a left-handed layout (hints on the '
          'left of the anvil), fewer effects, video chat, notifications and a daily reminder. Your account '
          'lives here too: sign in, sign out, or delete it.',
    ),
  ]),
  _Section(
    'In a puzzle',
    intro:
        'The number on each hint button is how many you have. Hints are yours to keep: get more by levelling '
        'up, and from embers, the Scrap Bin, the Forge Board and gifts.',
    [
      const _Entry(
        'anvil',
        'Forging words',
        'Swipe across the letters on the anvil and let go to forge a word. Words in the grid pour into the '
            'mold, and every puzzle has a word that uses all the letters. Fill the mold and the puzzle is '
            'forged!',
      ),
      const _Entry('turn', 'Turn', 'Shuffles the letters, to help you spot new words. Free, as often as you like.'),
      _Entry(
        'hammer',
        HintKind.hammer.title,
        'Reveals one empty letter at random. Every new smith starts with $startingHammers.',
      ),
      _Entry(
        'chisel',
        HintKind.chisel.title,
        'Tap it, then tap any empty cell to reveal that letter. Unlocks at Smith Level '
            '${HintKind.chisel.unlockLevel}.',
      ),
      _Entry(
        'sparks',
        HintKind.sparks.title,
        'Reveals up to $sparkShowerLetters letters at random, all at once. Unlocks at Smith Level '
            '${HintKind.sparks.unlockLevel}.',
      ),
      const _Entry(
        'scrap_bucket',
        'Scrap Bin',
        "Real words that aren't in the mold are **bonus words**. They drop into the Scrap Bin, and every "
            "$scrapBinCapacity are smelted into a free Hammer Strike. Tap the bin to see the ones you've found.",
      ),
      const _Entry(
        'ember',
        'Embers',
        'A glowing ember in a cell is a free hint. Forge the word through it to collect it.',
      ),
      const _Entry(
        'gilded',
        'Gilded cells',
        'A cell with a gold edge. Forge its word for a blueprint piece towards your next Masterwork.',
      ),
      const _Entry(
        'speaker',
        'Word meanings',
        'Tap a forged word in the mold, a bonus word in the Scrap Bin, or a word on the **Forged!** card to '
            'see what it means. Tap the speaker to hear it said.',
      ),
    ],
  ),
  const _Section('Signing in', [
    _Entry(
      'lock',
      'Why sign in?',
      'Sign in with Google or email to keep your progress safe, and the same on every phone. It also opens '
          'the **Daily Commission**, the **Forge Board**, **Friends**, **Co-op** and **Versus**. The campaign, '
          'Chapters and the Crucible work without it, even offline, and what you forge comes with you when '
          'you sign in.',
    ),
  ]),
];

class _SectionView extends StatelessWidget {
  const _SectionView({required this.section});

  final _Section section;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(section.title, style: displayStyle(16, color: Palette.molten)),
                    if (section.signIn) const _SignInTag(),
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  height: 1.5,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [Palette.molten.withValues(alpha: 0.7), Colors.transparent]),
                  ),
                ),
              ],
            ),
          ),
          ForgePanel(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (section.intro case final intro?) ...[
                  _Marked(intro, style: text.bodyMedium?.copyWith(color: Palette.steel, height: 1.4)),
                  _rule(),
                ],
                for (final (i, e) in section.entries.indexed) ...[if (i > 0) _rule(), _EntryView(entry: e)],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rule() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Divider(height: 1, color: Palette.ash),
  );
}

class _EntryView extends StatelessWidget {
  const _EntryView({required this.entry});

  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Palette.forgeBlack.withValues(alpha: 0.6),
            border: Border.all(color: const Color(0xFF8C6B47), width: 1.5),
          ),
          child: Center(child: GameIcon(entry.icon, size: 24, color: Palette.molten)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(entry.title, style: displayStyle(16)),
                  if (entry.signIn) const _SignInTag(),
                ],
              ),
              const SizedBox(height: 4),
              _Marked(entry.body, style: text.bodyMedium?.copyWith(height: 1.4)),
              if (entry.extra case final extra?) ...[const SizedBox(height: 10), extra],
            ],
          ),
        ),
      ],
    );
  }
}

/// The six ranks with their badges, two to a row.
class _RankLadder extends StatelessWidget {
  const _RankLadder();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, c) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final r in Rank.values)
            SizedBox(
              width: (c.maxWidth - 8) / 2,
              child: Row(
                children: [
                  RankBadge(rank: r, size: 26),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.labelMedium),
                        Text('Level ${r.minLevel}', style: text.labelSmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// "Needs sign-in", for what only works with an account.
class _SignInTag extends StatelessWidget {
  const _SignInTag();

  @override
  Widget build(BuildContext context) => ForgeFrame(
    kind: ForgeFrameKind.tab,
    shadow: false,
    padding: const EdgeInsets.fromLTRB(9, 3, 9, 4),
    child: Text('Needs sign-in', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Palette.molten)),
  );
}

/// [source] with its **starred** names in bold.
class _Marked extends StatelessWidget {
  const _Marked(this.source, {this.style});

  final String source;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final parts = source.split('**');
    final bold = TextStyle(fontWeight: FontWeight.w800, fontVariations: weight(800), color: Palette.whiteHeat);
    return Text.rich(
      TextSpan(
        children: [for (final (i, p) in parts.indexed) TextSpan(text: p, style: i.isOdd ? bold : null)],
      ),
      style: style,
    );
  }
}
