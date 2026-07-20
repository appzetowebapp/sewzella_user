import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:webview_master_app/config/app_config.dart';
import 'package:webview_master_app/config/theme_config.dart';
import 'package:webview_master_app/screens/webview_screen.dart';
import 'package:webview_master_app/utils/prefs_util.dart';
import 'package:webview_master_app/utils/fcm_background_handler.dart';
import 'package:webview_master_app/utils/notification_service.dart';

/// Main entry point of the application
void main() async {
  // Ensure Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  try {
    await Firebase.initializeApp();
    debugPrint('✅ Firebase initialized');

    // Register background message handler (for notifications when app is in background/terminated)
    // Foreground notifications are handled by NotificationService.onMessage listener
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    debugPrint('✅ Background message handler registered');
    debugPrint(
        '📱 Notification setup: Both foreground and background notifications enabled');
  } catch (e) {
    debugPrint('❌ Error initializing Firebase: $e');
    debugPrint('⚠️ Make sure google-services.json is added to android/app/');
  }

  // Initialize SharedPreferences
  await PrefsUtil.init();

  // Initialize Notification Service early
  // This sets up foreground notification handler (FirebaseMessaging.onMessage)
  // and handles all notification display logic
  try {
    await NotificationService().initialize();
    debugPrint('✅ Notification service initialized in main');
    debugPrint('📱 Foreground notifications: Enabled via NotificationService');
  } catch (e) {
    debugPrint('❌ Error initializing notification service in main: $e');
  }

  // Detect native Android version to enable accurate version-specific
  // edge-to-edge and WindowInsets rendering.
  if (Platform.isAndroid) {
    try {
      const platform = MethodChannel('app.channel.shared.data');
      final int sdkInt = await platform.invokeMethod('getSdkInt');
      AppConfig.androidSdkInt = sdkInt;
      debugPrint('📱 Detected Android SDK: $sdkInt');
    } catch (e) {
      debugPrint('⚠️ Failed to get Android SDK version: $e');
    }
  }

  // Hide the status bar completely during app launch so the splash screen 
  // can be truly full screen without any flickering. The status bar will be
  // restored dynamically when the webview is ready.
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual, 
    overlays: [SystemUiOverlay.bottom],
  );

  runApp(const MyApp());
}

/// Root widget of the application
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // Default to system theme mode
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
  }

  /// Load saved theme mode from preferences
  void _loadThemeMode() {
    final themeModeInt = PrefsUtil.getThemeMode();
    setState(() {
      _themeMode = ThemeMode.values[themeModeInt];
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: AppConfig.appName,

      // Theme configuration
      theme: ThemeConfig.lightTheme,
      darkTheme: ThemeConfig.darkTheme,
      themeMode: _themeMode,

      // Home screen
      home: const WebViewScreen(),

      // Builder for additional configuration
      builder: (context, child) {
        return child ?? const SizedBox.shrink();
      },
    );
  }
}
