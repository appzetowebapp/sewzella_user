import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_master_app/config/app_config.dart';

/// Utility class for managing status bar styling
/// All status bar colors can be configured in AppConfig
class StatusBarUtil {
  /// The SystemUiOverlayStyle for the app's primary teal theme.
  /// Light icons are used because the teal header is a dark-ish color.
  static SystemUiOverlayStyle get appThemeStyle => const SystemUiOverlayStyle(
        statusBarColor: AppConfig.appThemeStatusBarColor,
        statusBarIconBrightness: Brightness.light, // light icons on teal
        statusBarBrightness: Brightness.dark, // iOS: dark bg = light icons
        systemNavigationBarColor: AppConfig.navigationBarColorLight,
        systemNavigationBarIconBrightness: Brightness.dark,
      );

  /// The SystemUiOverlayStyle for the app's dark variant teal theme.
  static SystemUiOverlayStyle get appThemeDarkStyle =>
      const SystemUiOverlayStyle(
        statusBarColor: AppConfig.appThemeStatusBarColorDark,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: AppConfig.navigationBarColorDark,
        systemNavigationBarIconBrightness: Brightness.light,
      );

  /// Update status bar based on theme — always uses the teal brand color.
  /// On light theme: teal bar with light icons (matching the website header).
  /// On dark theme: dark teal bar with light icons.
  static void updateStatusBar(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(isDark ? appThemeDarkStyle : appThemeStyle);
  }

  /// Set status bar to the app's primary teal theme color imperatively.
  /// Call this from initState / didChangeDependencies when needed.
  static void setAppThemeStatusBar({bool isDark = false}) {
    SystemChrome.setSystemUIOverlayStyle(isDark ? appThemeDarkStyle : appThemeStyle);
  }

  /// Set status bar for splash screen (transparent on white bg → dark icons)
  static void setSplashStatusBar() {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }

  /// Set status bar for light theme
  static void setLightStatusBar() {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: AppConfig.statusBarColorLight,
        statusBarIconBrightness: AppConfig.statusBarIconBrightnessLight,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: AppConfig.navigationBarColorLight,
        systemNavigationBarIconBrightness:
            AppConfig.navigationBarIconBrightnessLight,
      ),
    );
  }

  /// Set status bar for dark theme
  static void setDarkStatusBar() {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: AppConfig.statusBarColorDark,
        statusBarIconBrightness: AppConfig.statusBarIconBrightnessDark,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: AppConfig.navigationBarColorDark,
        systemNavigationBarIconBrightness:
            AppConfig.navigationBarIconBrightnessDark,
      ),
    );
  }
}
