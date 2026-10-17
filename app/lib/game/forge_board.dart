import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/api_client.dart';
import '../net/board.dart';
import 'account.dart';

/// The Forge Board (shared/forge-board.md) once signed in; null otherwise.
/// Claims replace it with the board the server sends back.
final forgeBoardProvider = AsyncNotifierProvider<ForgeBoardController, ForgeBoard?>(
  ForgeBoardController.new,
  retry: (_, _) => null,
);

class ForgeBoardController extends AsyncNotifier<ForgeBoard?> {
  ApiClient? get _api => ref.read(apiClientProvider);

  @override
  Future<ForgeBoard?> build() async {
    final ready = ref.watch(accountProvider.select((a) => a.isReady));
    // New XP usually means order progress too: fetch it again.
    ref.watch(accountProvider.select((a) => a.server?.totalXp));
    final api = _api;
    if (!ready || api == null) return null;
    return api.board();
  }

  Future<void> refresh() async {
    final api = _api;
    if (api == null || !ref.read(accountProvider).isReady) return;
    try {
      final board = await api.board();
      if (ref.mounted) state = AsyncData(board);
    } on ApiException {
      // Keep showing what we had.
    }
  }

  Future<Reward> _claim(Future<BoardClaim> Function(ApiClient api) call) async {
    final claim = await call(_api!);
    if (!ref.mounted) return claim.reward;
    ref.read(accountProvider.notifier).applyProfile(claim.profile);
    state = AsyncData(claim.board);
    return claim.reward;
  }

  Future<Reward> claimStoke() => _claim((api) => api.claimStoke());
  Future<Reward> claimOrder(String slot) => _claim((api) => api.claimOrder(slot));
  Future<void> swapOrder(String slot) => _claim((api) => api.swapOrder(slot));
  Future<Reward> claimTrials() => _claim((api) => api.claimTrials());
  Future<Reward> claimGifts() => _claim((api) => api.claimGifts());

  Future<void> sendGift(String friendId) async {
    await _api!.sendGift(friendId);
    await refresh();
  }
}
