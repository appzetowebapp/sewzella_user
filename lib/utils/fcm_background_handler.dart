import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_master_app/config/app_config.dart';

/// Background message handler for Firebase Cloud Messaging.
/// Must be a top-level function registered via FirebaseMessaging.onBackgroundMessage.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();

  debugPrint('════════════════════════════');
  debugPrint('🆔 Message ID: ${message.messageId}');
  debugPrint('🔔 Notification: ${message.notification}');
  debugPrint('📦 Data: ${message.data}');
  debugPrint('🕒 Time: ${DateTime.now()}');
  debugPrint('════════════════════════════');

  final RemoteNotification? notification = message.notification;
  final Map<String, dynamic> data = message.data;

  // Resolve title/body: prefer notification payload fields, fall back to data payload.
  // The backend sends messages where notification.title/body may be null even
  // when the real content is in the data payload.
  final String title = (notification?.title?.isNotEmpty == true)
      ? notification!.title!
      : (data['title']?.toString() ?? '');
  final String body = (notification?.body?.isNotEmpty == true)
      ? notification!.body!
      : (data['body']?.toString() ?? data['message']?.toString() ?? '');

  debugPrint('📋 Resolved title: "$title"');
  debugPrint('📋 Resolved body: "$body"');

  // Skip notifications with no meaningful content.
  if (title.trim().isEmpty || (title == 'Notification' && body.trim().isEmpty)) {
    debugPrint('⚠️ Skipping empty/invalid background notification');
    return;
  }

  // NOTE: We never return early to let Firebase auto-display.
  // The "default" notification channel is created below with Importance.none,
  // so Firebase's auto-show is always silently discarded by the OS.
  // We are the sole source of truth for what the user sees.

  // Cross-isolate dedup: SharedPreferences is readable across the background
  // isolate and the main isolate, so duplicate messages sent within 30 s by the
  // backend (different message IDs, identical content) are suppressed here AND
  // in the foreground handler.
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final String dedupKey = 'fcm_dedup_${(title + body).hashCode.abs()}';
  final int? lastShownMs = prefs.getInt(dedupKey);
  final int nowMs = DateTime.now().millisecondsSinceEpoch;

  if (lastShownMs != null && (nowMs - lastShownMs) < 30000) {
    debugPrint('⚠️ Duplicate background notification suppressed (within 30 s): $title');
    return;
  }

  // --- Show local notification ---

  final FlutterLocalNotificationsPlugin notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await notificationsPlugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings(AppConfig.notificationIcon),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      ),
    ),
  );

  final androidPlugin = notificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  // Primary channel for our app's notifications
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      AppConfig.notificationChannelId,
      AppConfig.notificationChannelName,
      description: AppConfig.notificationChannelDescription,
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      showBadge: true,
      enableLights: true,
      ledColor: AppConfig.notificationColor,
    ),
  );

  // Silent sink channel — Firebase routes its blank auto-notifications to the
  // "default" channel. By owning that channel at Importance.none, Android drops
  // them before they reach the notification shade. Must be created in the
  // background isolate because channels don't persist across isolate restarts.
  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      'default',
      'Silent (Firebase fallback)',
      description: 'Silences blank auto-notifications from Firebase',
      importance: Importance.none,
      playSound: false,
      enableVibration: false,
      showBadge: false,
    ),
  );

  final int localNotificationId =
      (message.messageId ?? nowMs.toString()).hashCode.abs() % 2147483647;

  await notificationsPlugin.show(
    localNotificationId,
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        AppConfig.notificationChannelId,
        AppConfig.notificationChannelName,
        channelDescription: AppConfig.notificationChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        icon: AppConfig.notificationIcon,
        playSound: true,
        enableVibration: true,
        color: AppConfig.notificationColor,
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    ),
    payload: data.toString(),
  );

  // Record that this content was shown so the foreground handler (and any
  // subsequent background handler invocation) can suppress duplicates.
  await prefs.setInt(dedupKey, nowMs);
  debugPrint('✅ Background notification shown: $title (ID: $localNotificationId)');

  // Belt-and-suspenders: if Firebase somehow posted a blank notification before
  // this handler ran (e.g. on a device where "default" channel had higher
  // importance before we created it), cancel any active notification whose title
  // is null or empty — those are Firebase's blanks, not ours.
  if (androidPlugin != null) {
    final activeNotifications = await androidPlugin.getActiveNotifications() ?? [];
    for (final active in activeNotifications) {
      final bool isBlank =
          (active.title == null || active.title!.trim().isEmpty) &&
          active.id != localNotificationId;
      if (isBlank) {
        await notificationsPlugin.cancel(active.id!);
        debugPrint('🗑️ Cancelled blank Firebase auto-notification (ID: ${active.id})');
      }
    }
  }
}
