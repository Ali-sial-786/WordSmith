import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_info.dart';
import '../../audio/sfx.dart';
import '../../engine/hints.dart';
import '../../engine/progression.dart';
import '../../game/account.dart';
import '../../game/forge_board.dart';
import '../../game/names.dart';
import '../../net/api_client.dart';
import '../../net/board.dart';
import '../../net/hub_client.dart';
import '../../net/models.dart';
import '../../game/providers.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/avatar_badge.dart';
import '../../ui/widgets/crash_notice.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/game_icon.dart';
import '../../ui/widgets/metal_button.dart';
import '../../ui/widgets/rank_badge.dart';
import '../../ui/widgets/reward_popup.dart';
import '../../ui/widgets/xp_bar.dart';
import '../../update/app_updater.dart';
import '../coop/coop_entry.dart';
import '../update/update_sheet.dart';
import 'help_sheet.dart';
import '../../ui/widgets/forge_frame.dart';

/// Home screen.
class HallScreen extends ConsumerWidget {
  const HallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final account = ref.watch(accountProvider);
    final campaign = ref.watch(campaignProvider);
    final stage = profile.campaignStage;
    final finished = stage > campaign.maxStage;
    final chapter = campaign.chapterFor(finished ? campaign.maxStage : stage);
    final text = Theme.of(context).textTheme;
    final progress = profile.progress;
    final online = account.phase != AccountPhase.unavailable;
    return Scaffold(
      body: ForgeBackground(
        image: 'assets/images/bg_hall.webp',
        dim: 0.3,
        fire: 0.45,
        fireHeight: 0.32,
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
                        const Align(alignment: Alignment.centerRight, child: HelpButton()),
                        Text(
                          'WORDSMITH',
                          textAlign: TextAlign.center,
                          style: displayStyle(
                            40,
                            color: Palette.molten,
                          ).copyWith(shadows: [Shadow(color: Palette.ember, blurRadius: 28)]),
                        ),
                        Text(
                          'Forge words. Level up.',
                          textAlign: TextAlign.center,
                          style: text.titleSmall?.copyWith(color: Palette.steel),
                        ),
                        const SizedBox(height: 22),
                        const CrashNotice(),
                        const _UpdateBanner(),
                        if (online && !account.isReady) ...[_AccountBanner(state: account), const SizedBox(height: 14)],
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
                          label: finished ? 'Campaign complete' : 'Forge (Solo play)',
                          sublabel: finished
                              ? 'Every puzzle forged ten times over!'
                              : campaign.isMaster(stage)
                              ? '${chapter.name} · Puzzle ${stage - chapter.first + 1}'
                              : '${chapter.name} · Puzzle ${stage - chapter.first + 1} of ${chapter.count}',
                          icon: 'anvil',
                          primary: true,
                          height: 72,
                          onPressed: finished ? null : () => context.push('/play/$stage'),
                        ),
                        if (account.isReady) ...[
                          const SizedBox(height: 12),
                          const _DailyButton(),
                          const SizedBox(height: 12),
                          const _BoardButton(),
                        ],
                        const SizedBox(height: 12),
                        PlateButton(
                          label: 'The Crucible',
                          sublabel: _crucibleLine(
                            account.server?.survivalBest ??
                                switch (ref.read(storeProvider).loadSurvivalBest()) {
                                  final b? => SurvivalBest.fromJson(b),
                                  null => null,
                                },
                          ),
                          icon: 'ember',
                          onPressed: () => context.push('/crucible'),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: PlateButton(
                                label: 'Chapters',
                                sublabel: '9 metals',
                                icon: 'map',
                                onPressed: () => context.push('/chapters'),
                              ),
                            ),
                            if (online) ...[
                              const SizedBox(width: 12),
                              Expanded(
                                child: PlateButton(
                                  label: 'Friends',
                                  sublabel: account.isReady ? '${account.friendsOnline} online' : 'Sign in first',
                                  icon: 'friends',
                                  onPressed: account.isReady ? () => context.push('/friends') : null,
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
                                icon: 'tongs',
                                onPressed: account.isReady ? () => showCoopEntry(context) : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: PlateButton(
                                label: 'Versus',
                                sublabel: account.isReady
                                    ? 'Up to 5 smiths'
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
                        PlateButton(
                          key: const ValueKey('hall-team'),
                          label: 'Team Versus',
                          sublabel: account.isReady
                              ? 'Two teams, up to 3 smiths each'
                              : online
                              ? 'Sign in first'
                              : 'Coming soon',
                          icon: 'friends',
                          onPressed: account.isReady ? () => showRoomEntry(context, 'team') : null,
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

/// "A new version is out", from the server's /v1/version.
class _UpdateBanner extends ConsumerWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(serverVersionProvider).value;
    if (v == null || compareVersions(v.latest, appVersion) <= 0) return const SizedBox.shrink();
    final tooOld = compareVersions(appVersion, v.minSupported) < 0;
    final apk = ref.watch(appUpdaterProvider).supported ? v.apk : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (tooOld ? Palette.quenchRed : Palette.verdigris).withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tooOld ? Palette.quenchRed : Palette.verdigris),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tooOld
                ? kIsWeb
                      ? 'This version is too old for online play. Close the game and open it again to update.'
                      : apk != null
                      ? 'This version is too old for online play. Update to play with friends.'
                      : 'This version is too old for online play. Install Wordsmith ${v.latest} to play with friends.'
                : kIsWeb
                ? 'Wordsmith ${v.latest} is out! Close the game and open it again to update.'
                : apk != null
                ? 'Wordsmith ${v.latest} is out!'
                : 'Wordsmith ${v.latest} is out! Get it from whoever shared the game with you.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (apk != null) ...[
            const SizedBox(height: 10),
            PlateButton(
              label: 'Update now',
              primary: true,
              height: 46,
              onPressed: () => showUpdateSheet(context, version: v.latest, apk: apk),
            ),
          ],
        ],
      ),
    );
  }
}

/// Today's Daily Commission and the streak.
class _DailyButton extends ConsumerWidget {
  const _DailyButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(dailyProvider).value;
    final sublabel = info == null
        ? 'A new puzzle every day'
        : info.completed
        ? 'Forged today · ${info.streak}-day streak'
        : info.streak > 0
        ? 'Keep your ${info.streak}-day streak going'
        : 'A new puzzle every day';
    return PlateButton(
      label: 'Daily Commission',
      sublabel: sublabel,
      icon: 'flame',
      onPressed: () => context.push('/daily'),
    );
  }
}

/// Survival's solo mode: the best run so far, or what it is.
String _crucibleLine(SurvivalBest? best) => best == null || best.puzzles + best.words == 0
    ? 'Survival: forge words before they melt'
    : 'Survival · Best: ${best.puzzles} cleared, ${best.words} words';

/// The Forge Board, with a badge for rewards waiting. The first time the
/// Hall sees today's Daily Stoke unclaimed, it offers it.
class _BoardButton extends ConsumerStatefulWidget {
  const _BoardButton();

  @override
  ConsumerState<_BoardButton> createState() => _BoardButtonState();
}

class _BoardButtonState extends ConsumerState<_BoardButton> {
  /// The day the Stoke was last offered (once a day per app run).
  static String? _offered;

  @override
  void initState() {
    super.initState();
    ref.listenManual(forgeBoardProvider, (_, next) {
      final board = next.value;
      if (board == null || board.stoke.claimedToday || _offered == board.date) return;
      _offered = board.date;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) _offerStoke(board);
      });
    }, fireImmediately: true);
  }

  Future<void> _offerStoke(ForgeBoard board) async {
    final reward = board.stoke.track[board.stoke.day - 1];
    final claim = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: GameIcon('bellows', size: 40, color: Palette.molten),
        title: Text('Stoke the Forge · Day ${board.stoke.day}'),
        content: Text("Today's reward: ${reward.label}.", textAlign: TextAlign.center),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Later')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Stoke!')),
        ],
      ),
    );
    if (claim != true || !mounted) return;
    try {
      final got = await ref.read(forgeBoardProvider.notifier).claimStoke();
      if (!mounted) return;
      ref.read(sfxProvider).play(SfxId.claim);
      await showRewardPopup(context, got, title: 'The forge roars!');
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.friendly)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(forgeBoardProvider).value;
    final waiting = board?.waiting ?? 0;
    final orders = board?.orders.daily;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        PlateButton(
          label: 'Forge Board',
          sublabel: waiting > 0
              ? '$waiting reward${waiting == 1 ? '' : 's'} waiting'
              : orders == null
              ? 'Work orders, gifts and trials'
              : 'Work orders ${orders.where((o) => o.done).length}/${orders.length} · Weekly Trials',
          icon: 'scroll',
          onPressed: () => context.push('/board'),
        ),
        if (waiting > 0)
          Positioned(
            right: -4,
            top: -6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Palette.quenchRed,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Palette.whiteHeat, width: 1.5),
              ),
              child: Text('$waiting', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white)),
            ),
          ),
      ],
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
    return ForgePanel(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      gold: true,
      glint: true,
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${ref.watch(displayNamesProvider).of(invite.from, invite.fromUsername)} invited you to '
              '${modeName(invite.mode)}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          TextButton(
            onPressed: () {
              n.dismissInvite(invite);
              context.push('/room/${invite.code}?mode=${invite.mode}');
            },
            child: Text('Join', style: TextStyle(color: Palette.molten)),
          ),
          IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => n.dismissInvite(invite)),
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
      AccountPhase.needsSetup when state.server?.needsSetup == false => (
        'Confirm your age to keep playing online.',
        'Confirm',
        () => context.push('/setup'),
      ),
      AccountPhase.needsSetup => ('Pick your smith name to finish setting up.', 'Set up', () => context.push('/setup')),
      AccountPhase.notOffered => ("Online play isn't offered in Quebec.", 'More', () => context.push('/sign-in')),
      AccountPhase.failed => (
        state.error ?? "Can't reach the forge right now.",
        'Retry',
        () => ref.read(accountProvider.notifier).retry(),
      ),
      _ => ('Connecting to the forge…', null, null),
    };
    return ForgePanel(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Expanded(child: Text(message, style: text.bodyMedium)),
          if (action != null)
            TextButton(
              onPressed: onTap,
              child: Text(action, style: TextStyle(color: Palette.molten)),
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
      child: ForgePanel(
        padding: const EdgeInsets.all(16),
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
                      Row(
                        children: [
                          RankBadge(rank: Rank.forLevel(level), size: 18),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              name == null ? 'Smith Level $level' : '$rank · Smith Level $level',
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall,
                            ),
                          ),
                        ],
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
                        GameIcon(e.key.unlockedAt(level) ? e.key.name : 'lock', size: 20, color: Palette.molten),
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
