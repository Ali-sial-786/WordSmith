import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/masterwork_info.dart';
import '../../engine/masterworks.dart';
import '../../game/providers.dart';
import '../../ui/theme/palette.dart';
import '../../ui/theme/theme.dart';
import '../../ui/widgets/forge_background.dart';
import '../../ui/widgets/masterwork_art.dart';

/// The twelve Masterworks: finished ones in gold, the one being built as a
/// blueprint, the rest still to come.
class ArmoryScreen extends ConsumerWidget {
  const ArmoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = MasterworkProgress(ref.watch(profileProvider).masterworkPieces);
    final infos = ref.watch(masterworkInfoProvider).value ?? plainMasterworks;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('The Armory', style: displayStyle(22)),
      ),
      extendBodyBehindAppBar: true,
      body: ForgeBackground(
        image: 'assets/images/bg_hall.webp',
        dim: 0.7,
        fire: 0.5,
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    progress.allDone
                        ? 'Every Masterwork is forged. The smiths of legend salute you.'
                        : 'Gilded cells hide in campaign puzzles. Forge the word through one '
                              'to win a blueprint piece. ${progress.finished} of '
                              '${masterworkSpecs.length} Masterworks forged.',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(color: Palette.steel),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 180,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: infos.length,
                  itemBuilder: (context, i) => _Tile(
                    info: infos[i],
                    state: i < progress.finished
                        ? _State.done
                        : i == progress.finished
                        ? _State.building
                        : _State.locked,
                    collected: i < progress.finished
                        ? infos[i].spec.pieces
                        : i == progress.finished
                        ? progress.piecesInCurrent
                        : 0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _State { done, building, locked }

class _Tile extends StatelessWidget {
  const _Tile({required this.info, required this.state, required this.collected});

  final MasterworkInfo info;
  final _State state;
  final int collected;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final building = state == _State.building;
    return Semantics(
      button: state != _State.locked,
      label: switch (state) {
        _State.done => '${info.name}, forged',
        _State.building => '${info.name}, $collected of ${info.spec.pieces} pieces',
        _State.locked => 'A Masterwork still to come',
      },
      child: Material(
        // Ink paints on the nearest Material: this one, above the background.
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: state == _State.locked ? null : () => _showDetail(context),
          child: Ink(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: building ? blueprintPaper : Palette.soot.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: switch (state) {
                  _State.done => Palette.gold.withValues(alpha: 0.7),
                  _State.building => const Color(0xFF6FA8DC),
                  _State.locked => Palette.ash,
                },
              ),
            ),
            child: Column(
              children: [
                Expanded(
                  child: FittedBox(
                    child: MasterworkArt(spec: info.spec, collected: collected, locked: state == _State.locked),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  state == _State.locked ? '???' : info.name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelLarge?.copyWith(color: state == _State.done ? Palette.gold : null),
                ),
                if (building) Text('$collected / ${info.spec.pieces} pieces', style: text.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showDetail(BuildContext context) {
    final text = Theme.of(context).textTheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Palette.soot,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: state == _State.building ? blueprintPaper : Palette.forgeBlack,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: MasterworkArt(spec: info.spec, collected: collected, size: 160),
              ),
              const SizedBox(height: 14),
              Text(
                info.name,
                textAlign: TextAlign.center,
                style: displayStyle(24, color: state == _State.done ? Palette.gold : Palette.whiteHeat),
              ),
              const SizedBox(height: 6),
              if (info.blurb.isNotEmpty) Text(info.blurb, textAlign: TextAlign.center, style: text.bodyMedium),
              const SizedBox(height: 10),
              Text(
                state == _State.done
                    ? 'Forged.'
                    : '$collected of ${info.spec.pieces} blueprint pieces. Finishing it gives '
                          '$masterworkXp XP, a Chisel and a Spark Shower.',
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: Palette.steel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
