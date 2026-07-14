import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Powiadomienia push (FCM) — tylko na mobile. Na web pomijamy (inny mechanizm).

// Czyszczenie powiadomień z paska systemowego (po wejściu/wznowieniu apki).
final _localNotifications = FlutterLocalNotificationsPlugin();
bool _localNotifInited = false;

Future<void> clearDeliveredNotifications() async {
  if (kIsWeb) return;
  try {
    if (!_localNotifInited) {
      await _localNotifications.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );
      _localNotifInited = true;
    }
    // Kasuje wszystkie powiadomienia apki (także te pokazane przez FCM w tle).
    await _localNotifications.cancelAll();
  } catch (e) {
    debugPrint('CLEAR_NOTIF_ERROR: $e');
  }
}

Future<void> initFirebaseIfMobile() async {
  if (kIsWeb) return;
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('FIREBASE_INIT_ERROR: $e');
  }
}

// Po zalogowaniu: prośba o zgodę, pobranie tokenu FCM, zapis w Supabase,
// żeby serwer wiedział, na które urządzenie wysłać powiadomienie.
Future<void> registerPushToken() async {
  if (kIsWeb) return;
  try {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    final token = await messaging.getToken();
    if (token != null) await _saveToken(token);
    messaging.onTokenRefresh.listen(_saveToken);
  } catch (e) {
    debugPrint('PUSH_REGISTER_ERROR: $e');
  }
}

Future<void> _saveToken(String token) async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return;
  try {
    await Supabase.instance.client.from('device_tokens').upsert({
      'user_id': user.id,
      'token': token,
      'updated_at': DateTime.now().toIso8601String(),
    });
    debugPrint('PUSH_TOKEN_SAVED');
  } catch (e) {
    debugPrint('PUSH_TOKEN_SAVE_ERROR: $e');
  }
}
