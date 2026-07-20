package com.sewzella.user

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.mobasket.user/geolocation"
    private val STATUS_BAR_CHANNEL = "com.sewzella.user/statusbar"
    private val LOCATION_PERMISSION_REQUEST_CODE = 1

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkLocationPermission" -> {
                    val hasPermission = checkLocationPermission()
                    result.success(hasPermission)
                }
                "requestLocationPermission" -> {
                    requestLocationPermission()
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // ── Status bar icon brightness channel ────────────────────────────────
        // Called from Dart's _applyStatusBarColor() to update the icon colour
        // via WindowInsetsControllerCompat — required on Android 15+ (API 35+)
        // where the deprecated window.statusBarColor API is ignored.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STATUS_BAR_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setIconBrightness" -> {
                        val isLight = call.argument<Boolean>("isLight") ?: false
                        runOnUiThread {
                            val ctrl = WindowInsetsControllerCompat(window, window.decorView)
                            ctrl.isAppearanceLightStatusBars = isLight
                        }
                        result.success(true)
                    }
                    "getSdkInt" -> {
                        result.success(android.os.Build.VERSION.SDK_INT)
                    }
                    else -> result.notImplemented()
                }
            }
        // ─────────────────────────────────────────────────────────────────────
    }

    private fun checkLocationPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestLocationPermission() {
        if (!checkLocationPermission()) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION
                ),
                LOCATION_PERMISSION_REQUEST_CODE
            )
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // ── Edge-to-edge setup ──────────────────────────────────────────────
        // Keep edge-to-edge exclusively for Android 15+ (API 35+) where it works.
        // For Android 10-14, we rely on standard window layout to let the OS
        // natively draw the teal status bar and white navigation bar to bypass
        // Tecno/OEM black bar bugs.
        if (android.os.Build.VERSION.SDK_INT >= 35) {
            WindowCompat.setDecorFitsSystemWindows(window, false)
        }

        super.onCreate(savedInstanceState)
        
        // Ensure legacy OEMs don't draw a solid black bar
        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS)
        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_TRANSLUCENT_NAVIGATION)
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        
        if (android.os.Build.VERSION.SDK_INT >= 35) {
            window.statusBarColor = android.graphics.Color.TRANSPARENT
            window.navigationBarColor = android.graphics.Color.TRANSPARENT
        } else {
            window.statusBarColor = android.graphics.Color.parseColor("#087B84") // Teal
            window.navigationBarColor = android.graphics.Color.WHITE // White
        }

        // Set light status bar icons natively for the splash screen
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.hide(androidx.core.view.WindowInsetsCompat.Type.statusBars())
        controller.isAppearanceLightStatusBars = false
        
        // ── ANDROID 10 (API 29) OEM BUGFIX (Tecno, Xiaomi, etc.) ──────────────
        // When Flutter toggles SystemUiMode from hidden to manual, some Android 10
        // devices fail to dispatch the new WindowInsets. This listener forcefully triggers 
        // a layout pass, guaranteeing Flutter's viewPadding.top updates instantly.
        @Suppress("DEPRECATION")
        window.decorView.setOnSystemUiVisibilityChangeListener {
            window.decorView.requestApplyInsets()
        }
        // ─────────────────────────────────────────────────────────────────────

        // Request location permission on startup
        if (!checkLocationPermission()) {
            requestLocationPermission()
        }
    }
}
