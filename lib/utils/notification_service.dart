import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_master_app/services/api_service.dart';
import 'package:webview_master_app/config/app_config.dart';
import 'dart:io' show Platform;

/// Notification Service - Handles system tray notifications
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();

  factory NotificationService() => _instance;

  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  FirebaseMessaging? _firebaseMessaging;

  bool _isInitialized = false;

  // Track shown notifications to prevent duplicates by message ID
  final Set<String> _shownNotificationIds = <String>{};
  final Map<String, DateTime> _notificationTimestamps = <String, DateTime>{};

  // Content-based dedup: prevents backend from sending same notification twice in quick succession
  final Map<String, DateTime> _contentDedupeCache = <String, DateTime>{};

  /// Initialize notification service
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Android initialization settings
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings(AppConfig.notificationIcon);

    // iOS initialization settings
    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    // Combined initialization settings
    const InitializationSettings initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    // Initialize the plugin
    await _notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create notification channel for Android
    await _createNotificationChannel();

    // Initialize Firebase Messaging
    await _initializeFirebaseMessaging();

    _isInitialized = true;
    debugPrint('✅ Notification service initialized');
  }

  /// Initialize Firebase Cloud Messaging
  Future<void> _initializeFirebaseMessaging() async {
    try {
      _firebaseMessaging = FirebaseMessaging.instance;

      // Request notification permission for iOS (Android permissions handled via PermissionHandler)
      if (Platform.isIOS) {
        NotificationSettings settings =
            await _firebaseMessaging!.requestPermission(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
        );

        if (settings.authorizationStatus == AuthorizationStatus.authorized) {
          debugPrint('✅ Firebase notification permission granted (iOS)');
        } else if (settings.authorizationStatus ==
            AuthorizationStatus.provisional) {
          debugPrint(
              '⚠️ Firebase notification permission granted provisionally (iOS)');
        } else {
          debugPrint('❌ Firebase notification permission denied (iOS)');
        }
      }

      // Get FCM token
      String? token = await _firebaseMessaging!.getToken();
      if (token != null) {
        debugPrint('📱 FCM Token: $token');
      } else {
        debugPrint('⚠️ FCM Token is null');
      }

      // Listen for token refresh
      _firebaseMessaging!.onTokenRefresh.listen((newToken) {
        debugPrint('🔄 FCM Token refreshed: $newToken');
      });

      // Configure foreground message handler
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('📨 Foreground FCM message received: ${message.messageId}');
        _handleForegroundMessage(message);
      });

      // Handle notification tap when app is opened from terminated state
      FirebaseMessaging.instance
          .getInitialMessage()
          .then((RemoteMessage? message) {
        if (message != null) {
          debugPrint('📨 App opened from notification: ${message.messageId}');
        }
      });

      debugPrint('✅ Firebase Messaging initialized');
    } catch (e, stackTrace) {
      debugPrint('❌ Error initializing Firebase Messaging: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      // Continue even if Firebase fails - local notifications will still work
    }
  }

  /// Handle foreground FCM messages
  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    debugPrint('📨 Foreground message received: ${message.messageId}');
    debugPrint('📨 Message data: ${message.data}');

    RemoteNotification? notification = message.notification;
    Map<String, dynamic>? data = message.data;

    // Create unique ID for this notification
    String notificationId = message.messageId ?? '';

    // Clean old notification IDs (older than 5 minutes)
    _cleanOldNotificationIds();

    if (notification != null) {
      // Fall back to data payload when notification fields are null (backend sends empty notification object)
      final String resolvedTitle = (notification.title?.isNotEmpty == true)
          ? notification.title!
          : (data['title']?.toString() ?? '');
      final String resolvedBody = (notification.body?.isNotEmpty == true)
          ? notification.body!
          : (data['body']?.toString() ?? data['message']?.toString() ?? '');

      debugPrint('📨 Notification title: $resolvedTitle');
      debugPrint('📨 Notification body: $resolvedBody');

      // Skip notifications with no meaningful content
      if (resolvedTitle.trim().isEmpty ||
          (resolvedTitle == 'Notification' && resolvedBody.trim().isEmpty)) {
        debugPrint('⚠️ Skipping empty/invalid notification (no title or body)');
        return;
      }

      // In-memory dedup (same isolate, fast)
      if (_isRecentDuplicate(resolvedTitle, resolvedBody)) {
        debugPrint('⚠️ Duplicate notification suppressed (in-memory): $resolvedTitle');
        return;
      }

      // Cross-isolate dedup: catches duplicates where one message was processed
      // by the background handler and the next arrives in the foreground
      if (await _isPersistedDuplicate(resolvedTitle, resolvedBody)) {
        debugPrint('⚠️ Duplicate notification suppressed (cross-isolate): $resolvedTitle');
        return;
      }

      // Create a unique ID - use messageId if available, otherwise create from content
      final String uniqueId = notificationId.isNotEmpty
          ? notificationId
          : '${resolvedTitle}_${resolvedBody}_${message.sentTime?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch}';

      // Check if this notification was already shown (prevent duplicates by message ID)
      if (_shownNotificationIds.contains(uniqueId)) {
        debugPrint('⚠️ Duplicate notification detected, skipping: $uniqueId');
        return;
      }

      // Mark as shown
      _shownNotificationIds.add(uniqueId);
      _notificationTimestamps[uniqueId] = DateTime.now();
      _markContentShown(resolvedTitle, resolvedBody);

      // Ensure notification service is initialized
      if (!_isInitialized) {
        await initialize();
      }

      // Request permission if not granted
      if (!await Permission.notification.isGranted) {
        debugPrint('⚠️ Notification permission not granted, requesting...');
        final granted = await requestPermission();
        if (!granted) {
          debugPrint(
              '❌ Notification permission denied, cannot show notification');
          return;
        }
      }

      // Show notification
      await showNotification(
        title: resolvedTitle,
        body: resolvedBody,
        payload: data.toString(),
        imageUrl: notification.android?.imageUrl ??
            notification.apple?.imageUrl?.toString(),
        notificationId: uniqueId,
      );
    } else if (data.isNotEmpty) {
      // Handle data-only messages
      debugPrint('📨 Data-only message received');
      final title = data['title']?.toString() ?? '';
      final body =
          data['body']?.toString() ?? data['message']?.toString() ?? '';

      // Create unique ID for data-only messages
      final String uniqueId = notificationId.isNotEmpty
          ? notificationId
          : '${title}_${body}_${message.sentTime?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch}';

      // Skip notifications with no meaningful content
      if (title.trim().isEmpty || (title == 'Notification' && body.trim().isEmpty)) {
        debugPrint('⚠️ Skipping empty/invalid data-only notification');
        return;
      }

      // In-memory dedup (same isolate, fast)
      if (_isRecentDuplicate(title, body)) {
        debugPrint('⚠️ Duplicate data-only notification suppressed (in-memory): $title');
        return;
      }

      // Cross-isolate dedup
      if (await _isPersistedDuplicate(title, body)) {
        debugPrint('⚠️ Duplicate data-only notification suppressed (cross-isolate): $title');
        return;
      }

      // Check for duplicates by message ID
      if (_shownNotificationIds.contains(uniqueId)) {
        debugPrint(
            '⚠️ Duplicate data-only notification detected, skipping: $uniqueId');
        return;
      }

      // Mark as shown
      _shownNotificationIds.add(uniqueId);
      _notificationTimestamps[uniqueId] = DateTime.now();
      _markContentShown(title, body);

      if (!_isInitialized) {
        await initialize();
      }

      if (!await Permission.notification.isGranted) {
        await requestPermission();
      }

      await showNotification(
        title: title,
        body: body,
        payload: data.toString(),
        notificationId: uniqueId,
      );
    }
  }

  /// Clean old notification IDs to prevent memory buildup
  void _cleanOldNotificationIds() {
    final now = DateTime.now();
    final keysToRemove = <String>[];

    _notificationTimestamps.forEach((id, timestamp) {
      if (now.difference(timestamp).inMinutes > 5) {
        keysToRemove.add(id);
      }
    });

    for (final id in keysToRemove) {
      _shownNotificationIds.remove(id);
      _notificationTimestamps.remove(id);
    }

    // Clean content dedup cache (30-second window)
    _contentDedupeCache.removeWhere(
      (_, ts) => now.difference(ts).inSeconds > 30,
    );
  }

  /// Returns true if identical content was shown within the last 30 seconds
  /// (in-memory check — same isolate only).
  bool _isRecentDuplicate(String title, String body) {
    final lastShown = _contentDedupeCache['${title}_$body'];
    if (lastShown == null) return false;
    return DateTime.now().difference(lastShown).inSeconds < 30;
  }

  /// Returns true if identical content was shown within the last 30 seconds
  /// by ANY isolate (cross-isolate check via SharedPreferences).
  Future<bool> _isPersistedDuplicate(String title, String body) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final int? lastShownMs =
          prefs.getInt('fcm_dedup_${(title + body).hashCode.abs()}');
      if (lastShownMs == null) return false;
      return (DateTime.now().millisecondsSinceEpoch - lastShownMs) < 30000;
    } catch (_) {
      return false;
    }
  }

  /// Records that a notification with this content was just shown.
  /// Updates both the in-memory cache and SharedPreferences (for cross-isolate dedup).
  void _markContentShown(String title, String body) {
    _contentDedupeCache['${title}_$body'] = DateTime.now();
    // Persist for cross-isolate dedup (fire-and-forget — background handler reads this)
    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt(
        'fcm_dedup_${(title + body).hashCode.abs()}',
        DateTime.now().millisecondsSinceEpoch,
      );
    }).catchError((_) {});
  }

  /// Get FCM token
  Future<String?> getFCMToken() async {
    if (_firebaseMessaging == null) {
      await _initializeFirebaseMessaging();
    }
    return await _firebaseMessaging?.getToken();
  }

  Future<bool> saveFCMTokenToBackend({
    required String phone,
    String? platform,
  }) async {
    try {
      // Get FCM token
      final token = await getFCMToken();

      if (token == null || token.isEmpty) {
        debugPrint('❌ Cannot save FCM token: Token is null or empty');
        return false;
      }

      // Save to backend via API service
      final success = await ApiService().saveFCMToken(
        token: token,
        phone: phone,
        platform: platform,
      );

      if (success) {
        debugPrint('✅ FCM token saved to backend successfully');
      } else {
        debugPrint('❌ Failed to save FCM token to backend');
      }

      return success;
    } catch (e, stackTrace) {
      debugPrint('❌ Error saving FCM token to backend: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      return false;
    }
  }

  /// Create Android notification channels
  Future<void> _createNotificationChannel() async {
    try {
      final androidImplementation =
          _notificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidImplementation == null) {
        debugPrint('⚠️ Android notification plugin not available');
        return;
      }

      // Primary channel — used for all app-shown notifications
      const AndroidNotificationChannel mainChannel = AndroidNotificationChannel(
        AppConfig.notificationChannelId,
        AppConfig.notificationChannelName,
        description: AppConfig.notificationChannelDescription,
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        showBadge: true,
        enableLights: true,
        ledColor: AppConfig.notificationColor,
      );
      await androidImplementation.createNotificationChannel(mainChannel);
      debugPrint('✅ Notification channel created: ${AppConfig.notificationChannelId}');

      // Silent sink channel — Firebase sends blank notifications (empty notification
      // payload) to a channel called "default". By creating it ourselves with
      // Importance.none, Android silently discards those blank notifications before
      // they ever appear to the user.
      const AndroidNotificationChannel silentChannel = AndroidNotificationChannel(
        'default',
        'Silent (Firebase fallback)',
        description: 'Silences blank auto-notifications from Firebase',
        importance: Importance.none,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      );
      await androidImplementation.createNotificationChannel(silentChannel);
      debugPrint('✅ Silent fallback channel created: default (Importance.none)');
    } catch (e) {
      debugPrint('❌ Error creating notification channel: $e');
    }
  }

  /// Handle notification tap
  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('📱 Notification tapped: ${response.payload}');
  }

  /// Request notification permission
  Future<bool> requestPermission() async {
    try {
      // Check current permission status
      final currentStatus = await Permission.notification.status;
      debugPrint('🔔 Current notification permission status: $currentStatus');

      if (currentStatus.isGranted) {
        debugPrint('✅ Notification permission already granted');
        return true;
      }

      // For Android 13+, request permission
      if (Platform.isAndroid) {
        final status = await Permission.notification.request();
        debugPrint('🔔 Permission request result: $status');

        if (status.isGranted) {
          debugPrint('✅ Notification permission granted');
          return true;
        } else if (status.isPermanentlyDenied) {
          debugPrint('❌ Notification permission permanently denied');
          debugPrint('⚠️ User needs to enable notifications in app settings');
        } else {
          debugPrint('❌ Notification permission denied');
        }
        return status.isGranted;
      }

      // For iOS, permissions are handled by Firebase
      return currentStatus.isGranted;
    } catch (e) {
      debugPrint('❌ Error requesting notification permission: $e');
      return false;
    }
  }

  /// Show notification in system tray
  Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
    String? imageUrl,
    String? notificationId,
  }) async {
    debugPrint('🔔 showNotification called - Title: "$title", Body: "$body"');

    // Guard: never show empty or generic placeholder notifications
    if (title.trim().isEmpty || (title == 'Notification' && body.trim().isEmpty)) {
      debugPrint('⚠️ Skipping empty/invalid notification in showNotification');
      return;
    }

    if (!_isInitialized) {
      debugPrint('⚠️ Service not initialized, initializing now...');
      await initialize();
    }

    // Check permission
    final hasPermission = await Permission.notification.isGranted;
    debugPrint('🔔 Permission status: $hasPermission');

    if (!hasPermission) {
      debugPrint('❌ Notification permission not granted');
      debugPrint('⚠️ Requesting notification permission...');
      final granted = await requestPermission();
      if (!granted) {
        debugPrint('❌ Cannot show notification - permission denied');
        debugPrint('⚠️ Please enable notifications in Android Settings');
        return;
      }
    }

    // Generate notification ID - use provided ID or create one based on content
    // This ensures duplicate notifications with same content use same ID and replace each other
    final int localNotificationId;
    if (notificationId != null && notificationId.isNotEmpty) {
      // Use hash of the notification ID for consistent integer ID
      localNotificationId = notificationId.hashCode.abs() % 2147483647;
    } else {
      // Fallback: create ID based on title and body to prevent duplicates of same content
      final contentId = '${title}_$body';
      localNotificationId = contentId.hashCode.abs() % 2147483647;
    }

    // Android notification details
    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      AppConfig.notificationChannelId, // Must match channel ID
      AppConfig.notificationChannelName, // Must match channel name
      channelDescription: AppConfig.notificationChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      icon: AppConfig.notificationIcon,
      showWhen: true,
      styleInformation: const BigTextStyleInformation(''),
      color: AppConfig.notificationColor,
    );

    // iOS notification details
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    // Combined notification details
    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Show the notification
    try {
      await _notificationsPlugin.show(
        localNotificationId,
        title,
        body,
        notificationDetails,
        payload: payload,
      );
      debugPrint(
          '✅ Notification displayed successfully - ID: $localNotificationId');
    } catch (e, stackTrace) {
      debugPrint('❌ Error showing notification: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      rethrow;
    }

    // Cancel any blank notifications that Firebase may have auto-posted before
    // this handler ran (happens when the FCM message has a non-null but empty
    // notification payload and the app was in background).
    if (Platform.isAndroid) {
      _cancelBlankNotifications(localNotificationId);
    }
  }

  /// Finds and cancels active notifications with no title (Firebase auto-blanks).
  /// Runs fire-and-forget so it doesn't block the caller.
  void _cancelBlankNotifications(int ourId) {
    final androidPlugin = _notificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return;

    androidPlugin.getActiveNotifications().then((activeList) {
      for (final active in activeList ?? []) {
        if ((active.title == null || active.title!.trim().isEmpty) &&
            active.id != ourId) {
          _notificationsPlugin.cancel(active.id!);
          debugPrint('🗑️ Cancelled blank Firebase auto-notification (ID: ${active.id})');
        }
      }
    }).catchError((_) {});
  }
}
