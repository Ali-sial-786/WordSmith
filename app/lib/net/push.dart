import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Phone notifications for room invites (shared/push.md), behind an
/// interface so tests and builds without Firebase can swap it out.
abstract class PushService {
  /// Asks to show notifications (Android 13+). True if allowed.
  Future<bool> requestPermission();

  /// This phone's FCM registration token, or null if unavailable.
  Future<String?> token();
  Stream<String> get tokenRefresh;

  /// The data of a notification the player tapped while the app was running
  /// in the background.
  Stream<Map<String, dynamic>> get opened;

  /// The data of the notification that launched the app, if any.
  Future<Map<String, dynamic>?> initialOpen();

  /// Forgets this phone's token (sign-out, or notifications turned off).
  Future<void> deleteToken();
}

class DisabledPushService implements PushService {
  const DisabledPushService();

  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<String?> token() async => null;
  @override
  Stream<String> get tokenRefresh => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get opened => const Stream.empty();
  @override
  Future<Map<String, dynamic>?> initialOpen() async => null;
  @override
  Future<void> deleteToken() async {}
}

/// Uses classic FCM registration tokens, which the server's HTTP v1 sends
/// target. The newer installation-ID flow (register/onRegistered) is left
/// for when the server moves to direct sends, hence the deprecation ignores.
class FirebasePushService implements PushService {
  FirebasePushService([FirebaseMessaging? messaging]) : _fcm = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _fcm;

  @override
  Future<bool> requestPermission() async {
    try {
      final s = await _fcm.requestPermission();
      return s.authorizationStatus == AuthorizationStatus.authorized ||
          s.authorizationStatus == AuthorizationStatus.provisional;
    } on Object catch (e) {
      debugPrint('push permission: $e');
      return false;
    }
  }

  @override
  Future<String?> token() async {
    try {
      // ignore: deprecated_member_use
      return await _fcm.getToken();
    } on Object catch (e) {
      debugPrint('push token: $e');
      return null;
    }
  }

  @override
  // ignore: deprecated_member_use
  Stream<String> get tokenRefresh => _fcm.onTokenRefresh;

  @override
  Stream<Map<String, dynamic>> get opened => FirebaseMessaging.onMessageOpenedApp.map((m) => m.data);

  @override
  Future<Map<String, dynamic>?> initialOpen() async {
    try {
      return (await _fcm.getInitialMessage())?.data;
    } on Object catch (e) {
      debugPrint('push initial message: $e');
      return null;
    }
  }

  @override
  Future<void> deleteToken() async {
    try {
      // ignore: deprecated_member_use
      await _fcm.deleteToken();
    } on Object catch (e) {
      debugPrint('push delete token: $e');
    }
  }
}

/// The room an invite notification points at, if it's a valid one.
({String code, String mode})? inviteTarget(Map<String, dynamic>? data) {
  if (data == null || data['type'] != 'invite') return null;
  final code = (data['code'] as String? ?? '').toUpperCase();
  if (!RegExp(r'^[A-HJ-NP-Z2-9]{6}$').hasMatch(code)) return null;
  return (code: code, mode: data['mode'] == 'vs' ? 'vs' : 'coop');
}
