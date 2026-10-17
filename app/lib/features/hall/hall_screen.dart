import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../engine/hints.dart';
import '../../game/account.dart';
import '../../net/hub_client.dart';
import '../../game/providers.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/xp_bar.dart';
import '../coop/coop_entry.dart';

/// Home screen.
class HallScreen extends ConsumerWidget {
  const HallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final account = ref.watch(accountProvider);
    final campaign = ref.watch(campaignProvider);
    final stage = profile.campaignStage;
    final finished = stage > campaign.stageCount;
    final chapter = campaign.chapterFor(finished ? campaign.stageCount : stage);
    final text = Theme.of(context).textTheme;
    final progress = profile.progress;
    final online = account.phase != AccountPhase.unavailable;
    return Scaffold(
      body: ForgeBackground(
        image: 'assets/images/bg_hall.webp',
        dim: 0.45,
        blur: 1.5,
        fire: 0.85,
        fireHeight: 0.45,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: LayoutBuilder(
                builder: (context, c) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: c.maxHeight - 48),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'WORDSMITH',
                          textAlign: TextAlign.center,
                          style: displayStyle(40, color: Palette.molten).copyWith(
                            shadows: const [Shadow(color: Palette.ember, blurRadius: 28)],
                          ),
                        ),
                        Text(
                          'Forge words. Level up.',
                          textAlign: TextAlign.center,
                          style: text.titleSmall?.copyWith(color: Palette.steel),
                        ),
                        const SizedBox(height: 22),
                        if (online && !account.isReady) ...[
                          _AccountBanner(state: account),
                          const SizedBox(height: 14),
                        ],
                        for (final invite in account.invites) ...[
                          _InviteBanner(invite: invite),
                          const SizedBox(height: 10),
                        ],
                        _ProfileCard(
                          name: account.server?.username,
                          avatar: account.server?.avatar,
                          level: progress.level,
                          rank: profile.rank.title,
                          fraction: progress.fraction,
                          xpLabel: '${progress.xpIntoLevel} / ${progress.xpForNext} XP',
                          hints: {for (final k in HintKind.values) k: profile.hintCount(k)},
                          onTap: () => context.push('/profile'),
                        ),
                        const SizedBox(height: 20),
                        PlateButton(
                          label: finished ? 'Campaign complete' : 'Forge',
                          sublabel: finished
                              ? 'More puzzles are coming'
                              : '${chapter.name} · Puzzle ${stage - chapter.first + 1} of ${chapter.count}',
                          icon: 'anvil',
                          primary: true,
                          height: 72,
                          onPressed: finished ? null : () => context.push('/play/$stage'),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: PlateButton(
                                label: 'Chapters',
                                sublabel: 'Tin to Starmetal',
                                icon: 'map',
                                onPressed: () => context.push('/chapters'),
                              ),
                            ),
                            if (online) ...[
                              const SizedBox(width: 12),
                              Expanded(
                                child: PlateButton(
                                  label: 'Friends',
                                  sublabel: account.isReady
                                      ? '${account.friendsOnline} online'
                                      : 'Sign in first',
                                  icon: 'friends',
                                  onPressed: account.isReady
                                      ? () => context.push('/friends')
                                      : null,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: PlateButton(
                                label: 'Co-op',
                                sublabel: account.isReady
                                    ? 'Up to 4 smiths'
                                    : online
                                    ? 'Sign in first'
                                    : 'Coming soon',
                                icon: 'anvil',
                                onPressed: account.isReady ? () => showCoopEntry(context) : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: PlateButton(
                                label: 'Versus',
                                sublabel: account.isReady
                                    ? 'Race up to 5 smiths'
                                    : online
                                    ? 'Sign in first'
                                    : 'Coming soon',
                                icon: 'trophy',
                                onPressed: account.isReady ? () => showRoomEntry(context, 'vs') : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: PlateButton(
                                label: 'Profile',
                                icon: 'user',
                                height: 50,
                                onPressed: () => context.push('/profile'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: PlateButton(
                                label: 'Settings',
                                icon: 'settings',
                                height: 50,
                                onPressed: () => context.push('/settings'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A friend's invitation to a room.
class _InviteBanner extends ConsumerWidget {
  const _InviteBanner({required this.invite});

  final HubInvite invite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(accountProvider.notifier);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: Palette.ember.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Palette.molten),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${invite.fromUsername} invited you to ${invite.mode == 'vs' ? 'Versus' : 'Co-op'}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          TextButton(
            onPressed: () {
              n.dismissInvite(invite);
              context.push('/room/${invite.code}?mode=${invite.mode}');
            },
            child: const Text('Join', style: TextStyle(color: Palette.molten)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => n.dismissInvite(invite),
          ),
        ],
      ),
    );
  }
}

/// Nudges the player to sign in, finish setup, or retry the connection.
class _AccountBanner extends ConsumerWidget {
  const _AccountBanner({required this.state});

  final AccountState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final (message, action, onTap) = switch (state.phase) {
      AccountPhase.signedOut => (
        'Sign in to keep your progress safe and play with friends.',
        'Sign in',
        () => context.push('/sign-in'),
      ),
      AccountPhase.needsSetup => (
        'Pick your smith name to finish setting up.',
        'Set up',
        () => context.push('/setup'),
      ),
      AccountPhase.failed => (
        state.error ?? "Can't reach the forge right now.",
        'Retry',
        () => ref.read(accountProvider.notifier).retry(),
      ),
      _ => ('Connecting to the forge…', null, null),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: Palette.soot.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Palette.ember.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(message, style: text.bodyMedium)),
          if (action != null)
            TextButton(
              onPressed: onTap,
              child: Text(action, style: const TextStyle(color: Palette.molten)),
            ),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.name,
    required this.avatar,
    required this.level,
    required this.rank,
    required this.fraction,
    required this.xpLabel,
    required this.hints,
    required this.onTap,
  });

  final String? name;
  final String? avatar;
  final int level;
  final String rank;
  final double fraction;
  final String xpLabel;
  final Map<HintKind, int> hints;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Palette.soot.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF5C4733)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                if (avatar != null)
                  AvatarBadge(avatar: avatar!, size: 56)
                else
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Palette.ash,
                      border: Border.all(color: Palette.molten, width: 2),
                    ),
                    child: Center(
                      child: Text('$level', style: displayStyle(22, color: Palette.molten)),
                    ),
                  ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name ?? rank, style: displayStyle(18)),
                      Text(
                        name == null ? 'Smith Level $level' : '$rank · Smith Level $level',
                        style: text.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      XpBar(fraction: fraction),
                      const SizedBox(height: 4),
                      Text(xpLabel, style: text.labelSmall),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final e in hints.entries)
                  Opacity(
                    opacity: e.key.unlockedAt(level) ? 1 : 0.4,
                    child: Row(
                      children: [
                        GameIcon(
                          e.key.unlockedAt(level) ? e.key.name : 'lock',
                          size: 20,
                          color: Palette.molten,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          e.key.unlockedAt(level) ? '${e.value}' : 'Lv ${e.key.unlockLevel}',
                          style: text.labelLarge,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
