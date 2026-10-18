import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account.dart';

/// Names as this player sees them: the nickname they gave a friend (kept on
/// the server, so it follows them to other phones, and only they see it), or
/// else the player's own username. Everything that shows another player's
/// name goes through this, or through a room session's `nameOf`, which asks
/// [AccountController.nicknameOf].
class DisplayNames {
  const DisplayNames(this._nicknames);

  static const none = DisplayNames({});

  /// Friend user id → my nickname for them.
  final Map<String, String> _nicknames;

  /// My nickname for [id], if I gave them one.
  String? nicknameOf(String? id) => id == null ? null : _nicknames[id];

  /// How [id] (whose username is [username]) is shown to me.
  String of(String? id, String username) => nicknameOf(id) ?? username;
}

/// The signed-in player's [DisplayNames], from their friends list.
final displayNamesProvider = Provider<DisplayNames>((ref) {
  final friends = ref.watch(accountProvider.select((a) => a.friends.friends));
  return DisplayNames({for (final f in friends) f.id: ?f.nickname});
});
