import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_auth/smart_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_master_app/config/app_config.dart';
import 'package:webview_master_app/utils/connectivity_util.dart';
import 'package:webview_master_app/utils/download_service.dart';
import 'package:webview_master_app/utils/notification_service.dart';
import 'package:webview_master_app/utils/permission_handler_util.dart';
import 'package:webview_master_app/utils/prefs_util.dart';
import 'package:webview_master_app/utils/status_bar_util.dart';
import 'package:webview_master_app/widgets/exit_dialog.dart';
import 'package:webview_master_app/screens/splash_screen.dart';

/// WebView Screen - Main screen that loads the configured web URL
class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  double _loadingProgress = 0.0;
  bool _shareInProgress = false;

  bool _isOnline = true;
  bool _phoneListenerInjected = false;
  bool _linkInterceptorInjected = false;
  bool _locationButtonClickDetected = false;
  bool _isInitialLoad = true;
  bool _splashMinDurationElapsed = false;
  bool _pageLoadFailed = false;
  Set<String> _cachedUrls = {};
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  // ── Dynamic status bar ────────────────────────────────────────────────────
  // Starts with brand teal; updated automatically by JS colour detection on
  // every page load so the bar always matches the website's top section.
  Color _statusBarColor = Colors.white;
  Brightness _statusBarIconBrightness = Brightness.light; // light on teal
  // ─────────────────────────────────────────────────────────────────────────

  // Track pending download requests from API calls
  final Map<String, Map<String, dynamic>> _pendingDownloadRequests = {};

  // Track API request bodies captured from JavaScript
  final Map<String, String> _apiRequestBodies = {};
  late final PullToRefreshController _pullToRefreshController;
  final SmartAuth _smartAuth = SmartAuth.instance;
  @override
  void initState() {
    super.initState();
    _loadCachedUrls();
    _pullToRefreshController = PullToRefreshController(
      settings: PullToRefreshSettings(color: AppConfig.primaryColor),
      onRefresh: () async {
        final isConnected = await ConnectivityUtil.isConnected();
        if (!isConnected) {
          _pullToRefreshController.endRefreshing();
          if (mounted) {
            ScaffoldMessenger.of(context).removeCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: const [
                    Icon(Icons.wifi_off, color: Colors.white),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        "No internet connection. Please check your internet and try again.",
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
                backgroundColor: const Color(0xFF8E4692),
                duration: const Duration(seconds: 4),
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            );
          }
          return;
        }

        if (_webViewController != null) {
          _forceApplyStatusBarStyle();
          await _webViewController!.reload();
        }
      },
    );

    _forceApplyStatusBarStyle();
    _checkConnectivity();
    _initializeNotifications();
    _listenToConnectivityChanges();
    _initializePermissionsAndSplash();
  }

  Future<void> _initializePermissionsAndSplash() async {
    try {
      await PermissionHandlerUtil.requestAllPermissions();
    } catch (e) {
      debugPrint('Init Error Log: $e');
    }

    await Future.delayed(Duration(seconds: AppConfig.splashDurationSeconds));
    if (mounted) {
      setState(() {
        _splashMinDurationElapsed = true;
      });
    }
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _stopOTPListener();
    super.dispose();
  }

  Future<void> _loadCachedUrls() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _cachedUrls = (prefs.getStringList('cached_urls') ?? []).toSet();
      });
    } catch (e) {
      debugPrint('Error loading cached URLs: $e');
    }
  }

  bool _isUrlCached(String urlString) {
    if (_cachedUrls.contains(urlString)) return true;
    final withoutQuery = urlString.split('?').first;
    if (_cachedUrls.contains(withoutQuery)) return true;
    if (urlString.endsWith('/')) {
      if (_cachedUrls.contains(urlString.substring(0, urlString.length - 1))) return true;
    } else {
      if (_cachedUrls.contains('$urlString/')) return true;
    }
    return false;
  }

  bool _otpListenerActive = false;

  Future<void> _startOTPListener() async {
    if (!Platform.isAndroid || _otpListenerActive) return;
    _otpListenerActive = true;

    try {
      debugPrint('📱 Starting SMS Listener for OTP...');
      final res = await _smartAuth.getSmsWithUserConsentApi();
      if (res.hasData && res.data != null) {
        final code = res.data!.code;
        debugPrint('✅ OTP Extracted natively: $code');
        if (_webViewController != null && code != null) {
          await _webViewController!
              .evaluateJavascript(source: "window.__autofillOTP('$code');");
        }
      }
    } catch (e) {
      debugPrint('❌ OTP Listener error: $e');
    } finally {
      _otpListenerActive = false;
    }
  }

  void _stopOTPListener() {
    if (!Platform.isAndroid) return;
    _smartAuth.removeUserConsentApiListener();
    _otpListenerActive = false;
    debugPrint('🛑 SMS Listener stopped');
  }

  Future<bool> _onWillPop() async {
    if (_webViewController != null) {
      final canGoBack = await _webViewController!.canGoBack();

      if (canGoBack) {
        // --- PREVENT LOGIN -> HOME -> LOGIN REDIRECT LOOP ---
        try {
          final currentUrl = await _webViewController!.getUrl();
          final urlString = currentUrl?.toString() ?? '';

          // Check if we are on a login/auth page
          final bool isLoginPage = urlString.contains('/login') ||
              urlString.contains('/auth/') ||
              urlString.contains('/signin') ||
              urlString.contains('/users/login');

          if (isLoginPage && PrefsUtil.getAccessToken() == null) {
            final history = await _webViewController!.getCopyBackForwardList();
            if (history != null && (history.currentIndex ?? 0) > 0) {
              final previousIndex = history.currentIndex! - 1;
              final previousUrl =
                  history.list?[previousIndex].url.toString() ?? '';

              // Normalize URLs for comparison (remove trailing slashes)
              final normalizedPrevious =
                  previousUrl.replaceAll(RegExp(r'/$'), '');
              final normalizedHome =
                  AppConfig.webUrl.replaceAll(RegExp(r'/$'), '');

              // If previous page is Home/Root and we are on Login, going back
              // will likely just trigger another redirect to Login.
              if (normalizedPrevious == normalizedHome) {
                debugPrint(
                  '🔄 Back check: On login screen and previous page is home. '
                  'Preventing redirect loop by showing exit dialog.',
                );
                if (!mounted) return false;
                final shouldExit = await ExitDialog.show(context);
                return shouldExit;
              }
            }
          }
        } catch (e) {
          debugPrint('⚠️ Error checking history for redirect loop: $e');
        }
        // ----------------------------------------------------

        _webViewController!.goBack();
        return false; // Don't exit app
      }
    }

    // Show exit confirmation dialog using centralized widget
    if (!mounted) return false;

    final shouldExit = await ExitDialog.show(context);
    return shouldExit;
  }

  /// Initialize notification service
  Future<void> _initializeNotifications() async {
    try {
      await NotificationService().initialize();
      await NotificationService().requestPermission();
      debugPrint('✅ Notification service ready');
      await _saveFCMTokenIfPhoneAvailable();
    } catch (e) {
      debugPrint('❌ Error initializing notifications: $e');
    }
  }

  /// Save FCM token to backend if phone number is available
  Future<void> _saveFCMTokenIfPhoneAvailable() async {
    try {
      final phoneNumber = PrefsUtil.getPhoneNumber();
      if (phoneNumber != null && phoneNumber.isNotEmpty) {
        debugPrint('📱 Phone number found, saving FCM token to backend...');
        final success = await NotificationService().saveFCMTokenToBackend(
          phone: phoneNumber,
        );
        if (success) {
          debugPrint('✅ FCM token saved successfully');
        } else {
          debugPrint('⚠️ Failed to save FCM token');
        }
      }
    } catch (e) {
      debugPrint('❌ Error saving FCM token: $e');
    }
  }

  /// Handle native sharing from JavaScript
  Future<Map<String, dynamic>> _handleNativeShare(dynamic payload) async {
    if (_shareInProgress) {
      return <String, dynamic>{
        'success': false,
        'error': 'Share already in progress',
      };
    }

    try {
      _shareInProgress = true;

      final data = _normalizeSharePayload(payload);
      final title = data['title']!;
      final text = data['text']!;
      final url = data['url']!;

      final combined = <String>[
        if (title.isNotEmpty) title,
        if (text.isNotEmpty) text,
        if (url.isNotEmpty) url,
      ].join('\n');

      await Share.share(
        combined,
        subject: title.isNotEmpty ? title : null,
      );

      return <String, dynamic>{'success': true};
    } catch (error) {
      debugPrint('❌ Native Share Error: $error');
      return <String, dynamic>{
        'success': false,
        'error': error.toString(),
      };
    } finally {
      _shareInProgress = false;
    }
  }

  Map<String, String> _normalizeSharePayload(dynamic payload) {
    dynamic raw = payload;

    if (payload is List && payload.isNotEmpty) {
      raw = payload.first;
    }

    if (raw is String && raw.isNotEmpty) {
      try {
        raw = jsonDecode(raw) as Map<String, dynamic>;
      } catch (e) {
        // Not JSON, treat as text
        return <String, String>{
          'title': '',
          'text': raw.toString().trim(),
          'url': '',
        };
      }
    }

    if (raw is! Map) {
      return const <String, String>{
        'title': '',
        'text': '',
        'url': '',
      };
    }

    return <String, String>{
      'title': '${raw['title'] ?? ''}'.trim(),
      'text': '${raw['text'] ?? ''}'.trim(),
      'url': '${raw['url'] ?? ''}'.trim(),
    };
  }

  /// Handle blob URL download by extracting blob data via JavaScript
  Future<void> _handleBlobDownload({
    required InAppWebViewController controller,
    required String blobUrl,
    String? suggestedFilename,
    String? mimeType,
    bool isReceiptDownload = false,
  }) async {
    if (!mounted) return;

    final downloadService = DownloadService();

    try {
      debugPrint('🔵 Extracting blob data from: $blobUrl');

      // Create a completer to wait for JavaScript callback
      final completer = Completer<Map<String, dynamic>>();
      final handlerName =
          'blobDownloadHandler_${DateTime.now().millisecondsSinceEpoch}';

      // Add JavaScript handler to receive blob data
      controller.addJavaScriptHandler(
        handlerName: handlerName,
        callback: (args) {
          if (args.isNotEmpty) {
            try {
              final result =
                  jsonDecode(args[0].toString()) as Map<String, dynamic>;
              if (!completer.isCompleted) {
                completer.complete(result);
              }
            } catch (e) {
              debugPrint('❌ Error parsing blob data: $e');
              if (!completer.isCompleted) {
                completer.completeError(e);
              }
            }
          } else {
            if (!completer.isCompleted) {
              completer
                  .completeError(Exception('No data received from JavaScript'));
            }
          }
        },
      );

      // Execute JavaScript to extract blob
      final blobDataScript = '''
        (function() {
          try {
            var handlerName = '$handlerName';
            var blobUrl = '$blobUrl';
            var mimeType = '${mimeType ?? 'application/pdf'}';

            function sendResult(success, data, error, mime, size) {
              try {
                if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                  window.flutter_inappwebview.callHandler(handlerName, JSON.stringify({
                    success: success,
                    data: data || null,
                    error: error || null,
                    mimeType: mime || mimeType,
                    size: size || 0
                  }));
                } else {
                  console.error('Flutter handler not available');
                }
              } catch (e) {
                console.error('Error sending result:', e);
              }
            }

            function extractBlob() {
              try {
                var xhr = new XMLHttpRequest();
                xhr.open('GET', blobUrl, true);
                xhr.responseType = 'blob';

                xhr.onload = function() {
                  try {
                    if (xhr.status === 200 || xhr.status === 0) {
                      var blob = xhr.response;
                      if (!blob || blob.size === 0) {
                        sendResult(false, null, 'Blob is empty or null', mimeType, 0);
                        return;
                      }
                      var reader = new FileReader();
                      reader.onloadend = function() {
                        try {
                          sendResult(true, reader.result, null, blob.type || mimeType, blob.size);
                        } catch (e) {
                          sendResult(false, null, 'Error in onloadend: ' + (e.message || e.toString()), mimeType, 0);
                        }
                      };
                      reader.onerror = function() {
                        sendResult(false, null, 'Failed to read blob data', mimeType, 0);
                      };
                      reader.readAsDataURL(blob);
                    } else {
                      sendResult(false, null, 'HTTP error: ' + xhr.status, mimeType, 0);
                    }
                  } catch (e) {
                    sendResult(false, null, 'Error in onload: ' + (e.message || e.toString()), mimeType, 0);
                  }
                };

                xhr.onerror = function() {
                  sendResult(false, null, 'Network error loading blob', mimeType, 0);
                };

                xhr.ontimeout = function() {
                  sendResult(false, null, 'Timeout loading blob', mimeType, 0);
                };

                xhr.timeout = 30000;
                xhr.send();
              } catch (error) {
                sendResult(false, null, error.message || 'Unknown error', mimeType, 0);
              }
            }

            extractBlob();
          } catch (e) {
            console.error('Error in blob extraction script:', e);
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('$handlerName', JSON.stringify({
                success: false,
                error: 'Script error: ' + (e.message || e.toString())
              }));
            }
          }
        })();
      ''';

      await controller.evaluateJavascript(source: blobDataScript);

      // Wait for JavaScript callback (with timeout)
      final resultMap = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw Exception('Timeout waiting for blob data');
        },
      );

      if (resultMap['success'] != true) {
        throw Exception(resultMap['error'] ?? 'Failed to extract blob data');
      }

      final base64Data = resultMap['data'] as String;
      final blobMimeType =
          resultMap['mimeType'] as String? ?? mimeType ?? 'application/pdf';

      // Extract base64 data (remove data URL prefix)
      final base64Content =
          base64Data.contains(',') ? base64Data.split(',')[1] : base64Data;

      // Determine filename
      String filename = suggestedFilename ?? 'receipt.pdf';
      if (!filename.contains('.')) {
        // Add extension based on MIME type
        if (blobMimeType.contains('pdf')) {
          filename = '$filename.pdf';
        } else if (blobMimeType.contains('image')) {
          filename = '$filename.png';
        }
      }

      // Get download directory (try public Downloads for receipts, fallback to app-specific)
      bool hasPermission = false;
      if (isReceiptDownload) {
        hasPermission = await PermissionHandlerUtil.checkStoragePermission();
        if (!hasPermission) {
          hasPermission =
              await PermissionHandlerUtil.requestStoragePermission();
        }
      }

      Directory downloadDir;
      if (isReceiptDownload && hasPermission) {
        downloadDir = await downloadService.getDownloadDirectory(
            usePublicDownloads: true);
      } else {
        downloadDir = await downloadService.getDownloadDirectory(
            usePublicDownloads: false);
      }

      final filePath = '${downloadDir.path}/$filename';
      debugPrint('💾 Saving blob to: $filePath');

      // Decode base64 and save to file
      final bytes = base64Decode(base64Content);
      final file = File(filePath);
      await file.writeAsBytes(bytes);

      // For Android, try to add file to MediaStore to make it visible in Downloads
      if (Platform.isAndroid && isReceiptDownload) {
        try {
          final downloadService = DownloadService();
          await downloadService.addFileToMediaStore(
              filePath, filename, blobMimeType);
        } catch (e) {
          debugPrint('⚠️ Could not add file to MediaStore: $e');
        }
      }

      if (!mounted) return;

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isReceiptDownload
                          ? 'Receipt saved to Downloads'
                          : 'File saved to Downloads',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                filename,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'OPEN',
            textColor: Colors.white,
            onPressed: () async {
              await downloadService.openFile(filePath);
            },
          ),
        ),
      );
      debugPrint('✅ Blob download successful: $filePath');
    } catch (e) {
      debugPrint('❌ Error downloading blob: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _injectPhoneCaptureScript(
      InAppWebViewController controller) async {
    if (_phoneListenerInjected) {
      return;
    }
    try {
      const script = r"""
        (function() {
          if (window.__phoneCaptureInstalled) {
            return;
          }
          window.__phoneCaptureInstalled = true;

          function callFlutter(phoneValue) {
            if (!phoneValue) {
              return;
            }
            var phone = String(phoneValue).trim();
            if (!phone) {
              return;
            }

            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('savePhoneNumber', phone);
            } else if (window.webkit
              && window.webkit.messageHandlers
              && window.webkit.messageHandlers.savePhoneNumber
              && window.webkit.messageHandlers.savePhoneNumber.postMessage) {
              window.webkit.messageHandlers.savePhoneNumber.postMessage(phone);
            }
          }

          function attachToInput(input) {
            if (!input || input.__phoneListenerAttached) {
              return;
            }
            input.__phoneListenerAttached = true;

            var notify = function() {
              callFlutter(input.value);
            };

            input.addEventListener('change', notify);
            input.addEventListener('blur', notify);
            input.addEventListener('keyup', function() {
              var digits = (input.value || '').replace(/\D/g, '');
              if (digits.length >= 10) {
                callFlutter(input.value);
              }
            });
          }

          function attachToForms() {
            document.querySelectorAll('form').forEach(function(form) {
              if (form.__phoneSubmitAttached) {
                return;
              }
              form.__phoneSubmitAttached = true;
              form.addEventListener('submit', function() {
                var formData = new FormData(form);
                var phone = formData.get('phone')
                  || formData.get('mobile')
                  || formData.get('phone_number')
                  || '';
                if (!phone) {
                  var input = form.querySelector(
                    'input[type="tel"], input[name*="phone"], input[name*="mobile"], input[id*="phone"], input[id*="mobile"]'
                  );
                  if (input) {
                    phone = input.value;
                  }
                }
                callFlutter(phone);
              });
            });
          }

          function scanAndAttach() {
            var selectors = [
              'input[type="tel"]',
              'input[name*="phone"]',
              'input[name*="mobile"]',
              'input[id*="phone"]',
              'input[id*="mobile"]'
            ];
            selectors.forEach(function(selector) {
              document.querySelectorAll(selector).forEach(attachToInput);
            });
            attachToForms();
          }

          var observer = new MutationObserver(function() {
            scanAndAttach();
          });

          observer.observe(document.documentElement || document.body, {
            childList: true,
            subtree: true
          });

          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', scanAndAttach);
          } else {
            scanAndAttach();
          }
        })();
      """;

      await controller.evaluateJavascript(source: script);
      _phoneListenerInjected = true;
    } catch (e) {
      debugPrint('❌ Failed to inject phone capture script: $e');
      _phoneListenerInjected = false;
    }
  }

  /// Inject JavaScript to intercept API requests and capture POST bodies and RESPONSES
  Future<void> _injectApiInterceptorScript(
      InAppWebViewController controller) async {
    try {
      const script = r"""
        (function() {
          if (window.__apiInterceptorInstalled) {
            return;
          }
          window.__apiInterceptorInstalled = true;

          function callFlutterHandler(handlerName, data) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler(handlerName, data);
            }
          }

          // Intercept fetch API
          var originalFetch = window.fetch;
          window.fetch = async function(url, options) {
            var urlString = typeof url === 'string' ? url : url.url || url.toString();
            var isLogin = urlString.includes('/auth/login') || 
                          urlString.includes('/users/login') ||
                          urlString.includes('/auth/signup-verify') ||
                          urlString.includes('/v1/auth/login');
            
            // Call original fetch
            try {
              var response = await originalFetch.apply(this, arguments);
              
              // Clone the response to read it without consuming the original stream
              var clone = response.clone();
              
              if (isLogin) {
                 clone.json().then(data => {
                    callFlutterHandler('captureLoginResponse', JSON.stringify({
                      url: urlString,
                      body: data
                    }));
                 }).catch(err => {
                    console.error('Error reading login response:', err);
                 });
              }

              return response;
            } catch (e) {
              throw e;
            }
          };

          // Intercept XMLHttpRequest
          var originalXHROpen = XMLHttpRequest.prototype.open;
          var originalXHRSend = XMLHttpRequest.prototype.send;
          
          XMLHttpRequest.prototype.open = function(method, url, async, user, password) {
            this._method = method;
            this._url = url;
            return originalXHROpen.apply(this, arguments);
          };
          
          XMLHttpRequest.prototype.send = function(data) {
            var self = this;
            var url = this._url;
            
            if (url && (url.includes('login') || 
                        url.includes('register') ||
                        url.includes('signup') ||
                        url.includes('/v1/auth/login'))) {
               this.addEventListener('load', function() {
                  try {
                    var responseBody = self.responseText;
                    // Try parsing JSON
                    try {
                       var json = JSON.parse(responseBody);
                       callFlutterHandler('captureLoginResponse', JSON.stringify({
                          url: url,
                          body: json
                       }));
                    } catch(e) {
                       // Not JSON
                    }
                  } catch(e) {
                     console.error('Error capturing XHR login response:', e);
                  }
               });
            }
            
            return originalXHRSend.apply(this, arguments);
          };
        })();
      """;

      await controller.evaluateJavascript(source: script);

      // Add JavaScript handler to receive captured API requests
      controller.addJavaScriptHandler(
        handlerName: 'captureApiRequest',
        callback: (args) {
          // Existing existing handler logic...
        },
      );

      // Add Handler for Login Response
      controller.addJavaScriptHandler(
        handlerName: 'captureLoginResponse',
        callback: (args) async {
          if (args.isEmpty) return;

          // ── OTP TRIGGER ─────────────────────────────────────────────────────
          // If a login/signup API response is captured, an OTP is likely on its
          // way. Start the native SMS listener immediately so it's ready.
          _startOTPListener();
          // ───────────────────────────────────────────────────────────────────

          try {
            debugPrint('📦 RAW RESPONSE: ${args[0]}');

            final decoded = jsonDecode(args[0].toString());

            debugPrint('📦 DECODED RESPONSE: $decoded');

            Map<String, dynamic> body;

            if (decoded is Map &&
                decoded['body'] != null &&
                decoded['body'] is Map) {
              body = Map<String, dynamic>.from(decoded['body']);
            } else if (decoded is Map) {
              body = Map<String, dynamic>.from(decoded);
            } else {
              debugPrint('❌ Invalid response format');
              return;
            }

            debugPrint('🔐 Login/Signup Body: $body');

            String? accessToken;

            accessToken = body['token']?.toString();

            if (accessToken == null &&
                body['data'] != null &&
                body['data'] is Map) {
              accessToken = body['data']['token']?.toString();
            }

            if (accessToken == null &&
                body['result'] != null &&
                body['result'] is Map) {
              accessToken = body['result']['token']?.toString();
            }

            if (accessToken == null || accessToken.isEmpty) {
              debugPrint('❌ No access token found');
              return;
            }

            debugPrint(
              '✅ Found Access Token: '
              '${accessToken.substring(0, accessToken.length > 15 ? 15 : accessToken.length)}...',
            );

            await PrefsUtil.setAccessToken(accessToken);

            String? phone;

            if (body['user'] != null && body['user'] is Map) {
              final user = body['user'] as Map;

              phone =
                  user['phone']?.toString() ?? user['phoneNumber']?.toString();
            }

            if (phone == null && body['data'] != null && body['data'] is Map) {
              final dataObj = body['data'] as Map;

              if (dataObj['user'] != null && dataObj['user'] is Map) {
                final user = dataObj['user'] as Map;

                phone = user['phone']?.toString() ??
                    user['phoneNumber']?.toString();
              }
            }

            if (phone == null &&
                body['result'] != null &&
                body['result'] is Map) {
              final result = body['result'] as Map;

              if (result['customer'] != null && result['customer'] is Map) {
                final customer = result['customer'] as Map;

                phone = customer['phone']?.toString() ??
                    customer['phoneNumber']?.toString();
              }
            }

            if (phone != null && phone.isNotEmpty) {
              debugPrint('📱 Found Phone Number: $phone');

              String cleanedPhone = phone.replaceAll(RegExp(r'[^\d]'), '');

              // Remove India country code if present
              if (cleanedPhone.length > 10 && cleanedPhone.startsWith('91')) {
                cleanedPhone = cleanedPhone.substring(2);
              }

              debugPrint(
                '📱 Cleaned Phone Number: $cleanedPhone',
              );

              await PrefsUtil.setPhoneNumber(cleanedPhone);
            } else {
              debugPrint('⚠️ Phone number not found');
            }

            String? userId;

            if (body['user'] != null && body['user'] is Map) {
              userId = body['user']['id']?.toString();
            }

            if (userId == null && body['data'] != null && body['data'] is Map) {
              final dataObj = body['data'] as Map;

              if (dataObj['user'] != null && dataObj['user'] is Map) {
                userId = dataObj['user']['id']?.toString();
              }
            }

            if (userId != null && userId.isNotEmpty) {
              debugPrint('👤 User ID: $userId');
            }

            await _saveFCMTokenIfPhoneAvailable();

            debugPrint('🎉 Login data saved successfully');
          } catch (e, stackTrace) {
            debugPrint(
              '❌ Error parsing login/signup response: $e',
            );
            debugPrint(stackTrace.toString());
          }
        },
      );

      debugPrint('✅ API interceptor script injected successfully');
    } catch (e) {
      debugPrint('❌ Failed to inject API interceptor script: $e');
    }
  }

  /// Inject JavaScript to intercept phone, email, and WhatsApp button clicks
  Future<void> _injectLinkInterceptorScript(
      InAppWebViewController controller) async {
    if (_linkInterceptorInjected) {
      return;
    }
    try {
      const script = r"""
        (function() {
          if (window.__linkInterceptorInstalled) {
            return;
          }
          window.__linkInterceptorInstalled = true;

          function callFlutterHandler(handlerName, data) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler(handlerName, data);
            } else if (window.webkit
              && window.webkit.messageHandlers
              && window.webkit.messageHandlers[handlerName]
              && window.webkit.messageHandlers[handlerName].postMessage) {
              window.webkit.messageHandlers[handlerName].postMessage(data);
            }
          }
          
          // Maintain a local storage mirror of visited URLs
          var visitedUrls = JSON.parse(localStorage.getItem('visitedUrls') || '[]');
          
          function addUrlToCache(urlStr) {
             var cleanUrl = urlStr.split('#')[0];
             if (!visitedUrls.includes(cleanUrl)) {
                visitedUrls.push(cleanUrl);
                localStorage.setItem('visitedUrls', JSON.stringify(visitedUrls));
             }
          }
          
          addUrlToCache(location.href);
          
          function isUrlCached(urlStr) {
             var cleanUrl = urlStr.split('#')[0];
             return visitedUrls.includes(cleanUrl) || 
                    visitedUrls.includes(cleanUrl + '/') || 
                    visitedUrls.includes(cleanUrl.replace(/\/$/, ''));
          }
          
          // Intercept clicks on links for SPA and normal navigation
          document.addEventListener('click', function(e) {
            var target = e.target;
            while (target && target.tagName !== 'A') {
              target = target.parentElement;
            }
            
            if (target && target.tagName === 'A') {
              var href = target.getAttribute('href');
              if (href) {
                 if (href.startsWith('tel:') || 
                     href.startsWith('mailto:') || 
                     href.includes('wa.me') || 
                     href.includes('whatsapp.com') ||
                     href.startsWith('javascript:')) {
                   return;
                 }
                 
                 var targetUrl = new URL(href, location.href).href;
                 if (!navigator.onLine && !isUrlCached(targetUrl)) {
                   e.preventDefault();
                   e.stopPropagation();
                   callFlutterHandler('showOfflinePopup', targetUrl);
                   return;
                 }
                 
                 if (navigator.onLine) {
                   addUrlToCache(targetUrl);
                 }
              }
            }
          }, true);

          // Intercept SPA route changes
          var originalPushState = history.pushState;
          history.pushState = function(state, title, url) {
             if (url) {
                var targetUrl = new URL(url, location.href).href;
                if (!navigator.onLine && !isUrlCached(targetUrl)) {
                   callFlutterHandler('showOfflinePopup', targetUrl);
                   return; // BLOCK IT!
                }
                addUrlToCache(targetUrl);
             }
             return originalPushState.apply(this, arguments);
          };
          
          var originalReplaceState = history.replaceState;
          history.replaceState = function(state, title, url) {
             if (url) {
                var targetUrl = new URL(url, location.href).href;
                if (!navigator.onLine && !isUrlCached(targetUrl)) {
                   callFlutterHandler('showOfflinePopup', targetUrl);
                   return; // BLOCK IT!
                }
                addUrlToCache(targetUrl);
             }
             return originalReplaceState.apply(this, arguments);
          };
        })();
      """;

      await controller.evaluateJavascript(source: script);
      _linkInterceptorInjected = true;
    } catch (e) {
      debugPrint('❌ Failed to inject link interceptor script: $e');
      _linkInterceptorInjected = false;
    }
  }

  bool _connectivityChecked = false;

  /// Check initial connectivity status
  Future<void> _checkConnectivity() async {
    final isConnected = await ConnectivityUtil.isConnected();
    if (mounted) {
      setState(() {
        _isOnline = isConnected;
        _connectivityChecked = true;
      });
    }
  }

  /// Listen to connectivity changes
  void _listenToConnectivityChanges() {
    _connectivitySubscription = ConnectivityUtil.onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      final isConnected = ConnectivityUtil.isConnectivityResultConnected(
        results,
      );

      if (mounted) {
        if (!_isOnline && isConnected) {
          // Internet restored, reload webview
          if (_webViewController != null) {
            _webViewController!.setSettings(
              settings: InAppWebViewSettings(
                cacheMode: CacheMode.LOAD_DEFAULT,
              ),
            );
            _webViewController!.reload();
          }
        } else if (_isOnline && !isConnected) {
          // Internet lost, update cache mode
          if (_webViewController != null) {
            _webViewController!.setSettings(
              settings: InAppWebViewSettings(
                cacheMode: CacheMode.LOAD_CACHE_ELSE_NETWORK,
              ),
            );
          }
        }
        setState(() {
          _isOnline = isConnected;
        });
      }
    });
  }

  /// Retry loading the page
  Future<void> _retryLoad() async {
    await _checkConnectivity();
    if (_isOnline) {
      _webViewController?.reload();
    }
  }

  /// Check if URL should be launched externally (phone, email, WhatsApp, social media)
  bool _shouldLaunchExternally(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();

    // Phone calls, Email, SMS
    if (scheme == 'tel' ||
        scheme == 'callto' ||
        scheme == 'mailto' ||
        scheme == 'sms') {
      return true;
    }

    // WhatsApp
    if (scheme == 'whatsapp' ||
        scheme == 'whatsapp-api' ||
        host.contains('whatsapp.com') ||
        host.contains('wa.me')) {
      return true;
    }

    // Social media platforms
    final socialMediaDomains = [
      'facebook.com',
      'fb.com',
      'twitter.com',
      'x.com',
      'instagram.com',
      'linkedin.com',
      'youtube.com',
      'tiktok.com',
      'snapchat.com',
      'pinterest.com',
      'telegram.org',
      't.me',
      'messenger.com',
      'viber.com',
      'line.me',
      'wechat.com',
      'skype.com',
    ];

    for (var domain in socialMediaDomains) {
      if (host.contains(domain)) {
        return true;
      }
    }

    // Messaging apps
    if (['tg', 'telegram', 'viber', 'skype'].contains(scheme)) {
      return true;
    }

    // Payment & Stores
    if (['market', 'itms-apps', 'itms-appss'].contains(scheme) ||
        host.contains('play.google.com') ||
        host.contains('apps.apple.com')) {
      return true;
    }

    // UPI Payment Schemes
    if ([
      'upi',
      'tez',
      'phonepe',
      'paytm',
      'bhim',
      'cred',
      'mobikwik',
      'amazonpay'
    ].contains(scheme)) {
      return true;
    }

    // Check for UPI deep links in URL
    final urlString = uri.toString().toLowerCase();
    if (urlString.contains('upi://') || urlString.contains('upi:pay')) {
      return true;
    }

    return false;
  }

  /// Handle Razorpay UPI app SVG URL clicks
  /// Detects URLs like https://cdn.razorpay.com/app/paytm.svg and converts to UPI deep links
  Future<Uri?> _handleRazorpayUPIAppClick(Uri uri) async {
    try {
      final urlString = uri.toString().toLowerCase();
      final host = uri.host.toLowerCase();

      // Check if it's a Razorpay CDN URL for UPI apps
      // FIX: Use path.endsWith or contains check to handle query parameters
      if (host.contains('razorpay.com') &&
          urlString.contains('/app/') &&
          (uri.path.endsWith('.svg') || urlString.contains('.svg'))) {
        debugPrint('💳 Detected Razorpay UPI app SVG URL: $urlString');

        // Extract app name from URL (e.g., "paytm" from "https://cdn.razorpay.com/app/paytm.svg")
        final pathSegments = uri.pathSegments;
        String? appName;

        for (var segment in pathSegments) {
          if (segment.endsWith('.svg')) {
            appName = segment.replaceAll('.svg', '').toLowerCase();
            break;
          }
        }

        if (appName != null && appName.isNotEmpty) {
          debugPrint('💳 Extracted UPI app name: $appName');

          final normalizedAppName = appName
              .replaceAll('-', '')
              .replaceAll('_', '')
              .replaceAll(' ', '')
              .toLowerCase();

          final upiAppMap = {
            'paytm': 'paytm',
            'phonepe': 'phonepe',
            'googlepay': 'tez',
            'gpay': 'tez',
            'tez': 'tez',
            'bhim': 'bhim',
            'cred': 'cred',
            'mobikwik': 'mobikwik',
            'amazonpay': 'amazonpay',
            'amazon': 'amazonpay',
            'pop': 'pop',
            'moneyview': 'moneyview',
            'popupi': 'pop',
          };

          var upiScheme = upiAppMap[appName] ?? upiAppMap[normalizedAppName];

          if (upiScheme != null) {
            // Try to extract UPI payment parameters from JavaScript context
            try {
              if (_webViewController != null) {
                final upiParamsScript = '''
                  (function() {
                    try {
                      // Look for Razorpay payment data
                      var razorpayData = window.Razorpay || window.razorpay || {};
                      var paymentData = razorpayData.paymentData || {};
                      var upiParams = {};
                      
                      // Check URL parameters
                      var urlParams = new URLSearchParams(window.location.search);
                      if (urlParams.get('pa')) upiParams.pa = urlParams.get('pa');
                      if (urlParams.get('pn')) upiParams.pn = urlParams.get('pn');
                      
                      // Check in payment data
                      if (paymentData.upi && paymentData.upi.vpa) upiParams.pa = paymentData.upi.vpa;
                      
                      // Also scan page text for VPA if needed
                      // Return parameters as JSON string
                      return Object.keys(upiParams).length > 0 ? JSON.stringify(upiParams) : null;
                    } catch(e) { return null; }
                  })();
                ''';

                final upiParamsResult = await _webViewController!
                    .evaluateJavascript(source: upiParamsScript);

                if (upiParamsResult != null &&
                    upiParamsResult.toString() != 'null') {
                  try {
                    final paramsJson = jsonDecode(upiParamsResult.toString())
                        as Map<String, dynamic>;
                    if (paramsJson.isNotEmpty) {
                      final upiUri = Uri(
                        scheme: 'upi',
                        host: 'pay',
                        queryParameters: paramsJson.map(
                            (key, value) => MapEntry(key, value.toString())),
                      );
                      debugPrint('💳 Using UPI parameters from page: $upiUri');
                      return upiUri;
                    }
                  } catch (e) {
                    debugPrint('⚠️ Error parsing UPI params: $e');
                  }
                }
              }
            } catch (e) {
              debugPrint('⚠️ Could not get page context: $e');
            }

            // Fallback: If we can't find params, try to launch the app directly
            // Note: Launching 'paytm://' usually opens the app home screen.
            final upiUri = Uri(scheme: 'upi', host: 'pay');
            debugPrint('💳 Launching UPI Payment (generic): $upiUri');
            return upiUri;
          }
        }
      }
      return null;
    } catch (e) {
      debugPrint('❌ Error handling Razorpay UPI app click: $e');
      return null;
    }
  }

  /// Handle UPI app launches
  Future<bool> _handleUPIAppLaunch(Uri uri) async {
    try {
      final scheme = uri.scheme.toLowerCase();

      // List of known UPI schemes
      final knownUpiSchemes = [
        'upi',
        'tez',
        'phonepe',
        'paytm',
        'bhim',
        'cred',
        'mobikwik',
        'amazonpay',
        'gpay'
      ];

      if (knownUpiSchemes.contains(scheme) ||
          uri.toString().startsWith('upi://')) {
        debugPrint('💳 Detected UPI/Payment link: $uri');

        // Try launching external application mode
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          debugPrint('✅ UPI app launched');
          return true;
        } else {
          // Fallback attempt without checking canLaunchUrl (sometimes works on legacy Android or specific config)
          try {
            debugPrint(
                '⚠️ canLaunchUrl returned false, attempting launch anyway...');
            await launchUrl(uri, mode: LaunchMode.externalApplication);
            return true;
          } catch (e) {
            debugPrint('❌ Failed to launch UPI app: $e');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content:
                        Text('Could not open payment app. Is it installed?')),
              );
            }
          }
        }
      }
      return false;
    } catch (e) {
      debugPrint('❌ Error handling UPI app launch: $e');
      return false;
    }
  }

  /// Handle Android Intent URLs specifically
  Future<void> _handleIntentUrl(Uri uri) async {
    try {
      debugPrint('🤖 Attempting to launch intent: $uri');
      // On Android, launchUrl with externalApplication mode handles intents if the app is installed
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (e) {
      debugPrint('❌ Failed to launch intent directly: $e');
    }

    // Fallback handling if launch failed
    try {
      final intentString = uri.toString();
      String? fallbackUrl;

      // Try different patterns for browser_fallback_url
      final patterns = ['browser_fallback_url=', 'S.browser_fallback_url='];

      for (var pattern in patterns) {
        if (intentString.contains(pattern)) {
          final fallbackBlock = intentString
              .substring(intentString.indexOf(pattern) + pattern.length);
          final endIndex = fallbackBlock.indexOf(';');

          if (endIndex != -1) {
            final fallbackUrlEncoded = fallbackBlock.substring(0, endIndex);
            fallbackUrl = Uri.decodeFull(fallbackUrlEncoded);
            break;
          }
        }
      }

      if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
        debugPrint('🔄 Intent failed, using fallback: $fallbackUrl');
        final fallbackUri = Uri.parse(fallbackUrl);

        // Launch fallback URL externally (e.g. Chrome) to avoid WebView redirect loops
        // and provide better UX for things like Maps directions.
        await _launchExternalUrl(fallbackUri);
      } else {
        debugPrint('⚠️ No fallback URL found in intent');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open map application.')),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Failed to handle intent fallback: $e');
    }
  }

  /// Launch URL externally using url_launcher
  Future<void> _launchExternalUrl(Uri uri) async {
    try {
      if (await _handleUPIAppLaunch(uri)) return;

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        debugPrint('✅ External URL launched successfully: $uri');
      } else {
        // Try launching anyway for intent schemes or special cases
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (e) {
          debugPrint('❌ Cannot launch URL: $uri');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Cannot open: ${uri.scheme}://...'),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('❌ Error launching external URL: $e');
    }
  }

  // ─── Dynamic Status Bar Color Helpers ──────────────────────────────────────

  /// Parse a CSS colour string (rgb / rgba / hex) returned by JavaScript
  /// into a Flutter [Color].  Returns null if parsing fails.
  Color? _parseCssColor(String css) {
    try {
      final s = css.trim().toLowerCase();

      // rgb(r, g, b)  or  rgba(r, g, b, a)
      final rgbMatch =
          RegExp(r'rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)').firstMatch(s);
      if (rgbMatch != null) {
        final r = int.parse(rgbMatch.group(1)!);
        final g = int.parse(rgbMatch.group(2)!);
        final b = int.parse(rgbMatch.group(3)!);
        // Treat fully transparent (r=g=b=0 comes from rgba(0,0,0,0)) as null
        if (s.contains('rgba') && s.contains(', 0)')) return null;
        return Color.fromARGB(255, r, g, b);
      }

      // #rrggbb  or  #rgb
      if (s.startsWith('#')) {
        var hex = s.substring(1);
        if (hex.length == 3) {
          hex = hex.split('').map((c) => '$c$c').join();
        }
        if (hex.length == 6) {
          return Color(int.parse('FF$hex', radix: 16));
        }
      }
    } catch (_) {}
    return null;
  }

  /// Compute relative luminance of [color] (per WCAG 2.x).
  /// Returns a value in [0, 1]; > 0.35 is considered "light".
  double _relativeLuminance(Color color) {
    double linearize(int c) {
      final s = c / 255.0;
      return s <= 0.03928
          ? s / 12.92
          : ((s + 0.055) / 1.055) * ((s + 0.055) / 1.055);
    }

    return 0.2126 * linearize(color.red) +
        0.7152 * linearize(color.green) +
        0.0722 * linearize(color.blue);
  }

  void _forceApplyStatusBarStyle() {
    // On Android 10-14, edgeToEdge is disabled. We explicitly color the OS status bar teal
    // and the navigation bar white to seamlessly blend with the app.
    final Color nativeStatusBarColor =
        (Platform.isAndroid && AppConfig.androidSdkInt < 35)
            ? _statusBarColor
            : Colors.transparent;
    final Color nativeNavBarColor =
        (Platform.isAndroid && AppConfig.androidSdkInt < 35)
            ? Colors.white
            : Colors.transparent;

    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: nativeStatusBarColor,
        systemNavigationBarColor: nativeNavBarColor,
        statusBarIconBrightness: _statusBarIconBrightness,
        statusBarBrightness: _statusBarIconBrightness == Brightness.light
            ? Brightness.dark
            : Brightness.light,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
    );
  }

  /// Parse [cssColor], decide icon brightness, then update state and system UI.
  void _applyStatusBarColor(String cssColor) {
    final parsed = _parseCssColor(cssColor);
    if (parsed == null) return; // transparent / unparsable → keep current

    final lum = _relativeLuminance(parsed);
    // Light background → dark icons; Dark background → light icons.
    final icons = lum > 0.35 ? Brightness.dark : Brightness.light;

    if (!mounted) return;
    setState(() {
      _statusBarColor = parsed;
      _statusBarIconBrightness = icons;
    });

    // The Container widget (sized to viewPadding.top) now handles the visual
    // colour. Set statusBarColor to transparent so it doesn't fight with the
    // Container on Android and keeps iOS behaviour correct.
    _forceApplyStatusBarStyle();

    // On Android 15+ (API 35+), additionally update icon appearance via the
    // native channel so WindowInsetsControllerCompat is called directly —
    // this covers cases where the deprecated SystemChrome path is ignored.
    if (Platform.isAndroid) {
      const _channel = MethodChannel('com.sewzella.user/statusbar');
      _channel.invokeMethod('setIconBrightness', {
        'isLight': icons == Brightness.dark, // isLight=true means dark icons
      }).catchError((_) {/* channel not yet set up or called too early */});
    }

    debugPrint('🎨 Status bar → $cssColor | lum=${lum.toStringAsFixed(2)} | '
        'icons=${icons == Brightness.light ? "light" : "dark"}');
  }

  /// Inject JS that detects the website's top header background colour and
  /// posts it back to Flutter via the [updateStatusBarColor] handler.
  Future<void> _injectStatusBarColorDetector(
      InAppWebViewController controller) async {
    const script = r'''
      (function() {
        if (window.__statusBarDetectorInstalled) return;
        window.__statusBarDetectorInstalled = true;

        function getEffectiveBg(el) {
          while (el && el !== document.documentElement) {
            var st = window.getComputedStyle(el);
            
            // 1. Check if there's a background gradient (often used in headers)
            var bgImg = st.backgroundImage;
            if (bgImg && bgImg.includes('gradient')) {
              // Extract the first rgb/rgba or hex color from the gradient string
              var match = bgImg.match(/(rgb\([^)]+\)|rgba\([^)]+\)|#[a-fA-F0-9]{3,8})/);
              if (match) {
                return match[1];
              }
            }
            
            // 2. Fallback to normal background color
            var bg = st.backgroundColor;
            if (bg && bg !== 'transparent' && bg !== 'rgba(0, 0, 0, 0)') {
              return bg;
            }
            el = el.parentElement;
          }
          return null;
        }

        function detectTopColor() {
          // Use elementsFromPoint to perfectly identify what is visibly painted
          // at the top center of the screen, just beneath the status bar. This
          // bypasses any issues with deeply nested transparent wrappers holding
          // a coloured child div.
          var x = window.innerWidth / 2;
          var y = 5; // 5 pixels down to ensure we hit the page body, not edges
          
          var els = document.elementsFromPoint(x, y);
          if (els && els.length > 0) {
            for (var i = 0; i < els.length; i++) {
              var el = els[i];
              var st = window.getComputedStyle(el);
              
              // 1. Check for gradients
              var bgImg = st.backgroundImage;
              if (bgImg && bgImg.includes('gradient')) {
                var match = bgImg.match(/(rgb\([^)]+\)|rgba\([^)]+\)|#[a-fA-F0-9]{3,8})/);
                if (match) return match[1];
              }
              
              // 2. Check for solid colours
              var bg = st.backgroundColor;
              if (bg && bg !== 'transparent' && bg !== 'rgba(0, 0, 0, 0)') {
                // If it's highly transparent (e.g. 0.1 alpha overlay), skip it
                // and keep looking underneath so we get the true visual colour.
                if (bg.startsWith('rgba')) {
                   var parts = bg.split(',');
                   if (parts.length === 4) {
                     var alpha = parseFloat(parts[3]);
                     if (alpha < 0.5) continue;
                   }
                }
                return bg;
              }
            }
          }

          // Fallback to html/body if nothing solid is found
          return window.getComputedStyle(document.body).backgroundColor || 'rgb(255,255,255)';
        }

        var lastColor = null;
        function report() {
          var color = detectTopColor();
          
          if (color !== lastColor) {
            // Only accept colour updates if we are at the top of the page,
            // or if the element we hit is a fixed/sticky header. This prevents
            // the status bar from wildly changing colours as the user scrolls
            // down into normal page content.
            var isFixed = false;
            var els = document.elementsFromPoint(window.innerWidth / 2, 5);
            if (els.length > 0) {
              var pos = window.getComputedStyle(els[0]).position;
              if (pos === 'fixed' || pos === 'sticky') isFixed = true;
            }
            
            if (window.scrollY <= 10 || isFixed) {
              lastColor = color;
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('updateStatusBarColor', color);
              }
            }
          }
        }

        // Run immediately, then continuously poll every 250ms.
        // This is extremely cheap (single raycast) and guarantees that lazy-loaded
        // React/Vue headers or SPA navigations are caught instantly.
        report();
        setInterval(report, 250);
      })();
    ''';

    try {
      await controller.evaluateJavascript(source: script);
    } catch (e) {
      debugPrint('⚠️ Status bar detector inject failed: $e');
    }
  }

  Future<void> _injectOTPAutofillScript(
      InAppWebViewController controller) async {
    const script = '''
      (function() {
        if (window.__otpInjectorReady) return;
        window.__otpInjectorReady = true;

        let listenerStarted = false;

        function tagOTPInputs() {
          const inputs = document.querySelectorAll('input[type="number"], input[type="text"], input[type="tel"]');
          let foundOtpInput = false;
          
          inputs.forEach(input => {
            const name = (input.name || '').toLowerCase();
            const id = (input.id || '').toLowerCase();
            const placeholder = (input.placeholder || '').toLowerCase();
            const type = (input.type || '').toLowerCase();
            const cls = (input.className || '').toLowerCase();
            const isOtp = name.includes('otp') || id.includes('otp') || placeholder.includes('otp') || cls.includes('otp') ||
                (input.maxLength && input.maxLength <= 6 && (name.includes('code') || id.includes('code') || placeholder.includes('code') || cls.includes('code'))) ||
                (type === 'number' && input.maxLength === 1) || // Common React 6-box input
                (type === 'tel' && input.maxLength === 1);
            
            if (isOtp) {
              
              foundOtpInput = true;
              
              if (!input.hasAttribute('autocomplete')) {
                input.setAttribute('autocomplete', 'one-time-code');
              }
            }
          });
          
          // Start Android listener if we found an OTP input and haven't started it yet
          if (foundOtpInput && !listenerStarted) {
            listenerStarted = true;
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('startOTPListener');
            }
          }
        }
        
        // Run immediately and whenever DOM changes (for SPAs/React)
        tagOTPInputs();
        const observer = new MutationObserver(() => {
           tagOTPInputs();
        });
        observer.observe(document.body, { childList: true, subtree: true });

        // Provide bridge function for Flutter to call
        window.__autofillOTP = function(otp) {
          if (!otp) return false;
          
          const inputs = document.querySelectorAll('input[type="number"], input[type="text"], input[type="tel"]');
          const otpInputs = Array.from(inputs).filter(i => {
            const n = (i.name || '').toLowerCase();
            const id = (i.id || '').toLowerCase();
            const p = (i.placeholder || '').toLowerCase();
            const c = (i.className || '').toLowerCase();
            const type = (i.type || '').toLowerCase();
            return n.includes('otp') || id.includes('otp') || p.includes('otp') || c.includes('otp') ||
                   n.includes('code') || id.includes('code') || p.includes('code') || c.includes('code') ||
                   i.getAttribute('autocomplete') === 'one-time-code' ||
                   ((type === 'number' || type === 'tel') && i.maxLength === 1);
          });
          
          if (otpInputs.length === 0) return false;
          
          // Helper to fire events and bypass strict Virtual DOM state (React/Vue)
          function setNativeValue(element, value, key) {
             element.focus();
             element.value = '';
             
             try {
                // 1. Try execCommand (most reliable, generates isTrusted=true native events)
                document.execCommand('insertText', false, value);
             } catch(e) {}
             
             // 2. React 15/16/17 value setter bypass
             const valueSetter = Object.getOwnPropertyDescriptor(element, 'value');
             const prototype = Object.getPrototypeOf(element);
             const prototypeValueSetter = Object.getOwnPropertyDescriptor(prototype, 'value');

             if (valueSetter && prototypeValueSetter && valueSetter.set && valueSetter.set !== prototypeValueSetter.set) {
                 prototypeValueSetter.set.call(element, value);
             } else if (valueSetter && valueSetter.set) {
                 valueSetter.set.call(element, value);
             } else {
                 element.value = value;
             }
             
             // 3. Reset React's internal valueTracker so it doesn't suppress the event
             if (element._valueTracker) {
                 element._valueTracker.setValue('');
             }
             
             // 4. Broadcast all possible events
             if (key) {
               element.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: key }));
               element.dispatchEvent(new KeyboardEvent('keypress', { bubbles: true, key: key }));
             }
             element.dispatchEvent(new Event('input', { bubbles: true }));
             element.dispatchEvent(new Event('change', { bubbles: true }));
             if (key) {
               element.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: key }));
             }
             
             element.blur();
          }
          
          let filled = false;
          
          // Case 1: Single input field
          if (otpInputs.length === 1 && (!otpInputs[0].maxLength || otpInputs[0].maxLength >= otp.length)) {
            setNativeValue(otpInputs[0], otp, otp[otp.length-1]);
            filled = true;
          }
          // Case 2: Split input fields
          else {
            const emptyBoxes = otpInputs.filter(i => (i.maxLength === 1 || i.maxLength === -1 || i.maxLength === '') && (!i.value || i.value === ''));
            if (emptyBoxes.length >= otp.length) {
              for (let i = 0; i < otp.length; i++) {
                setNativeValue(emptyBoxes[i], otp[i], otp[i]);
              }
              filled = true;
            } else if (otpInputs.length >= otp.length) {
              // Even if not empty, overwrite
              for (let i = 0; i < otp.length; i++) {
                setNativeValue(otpInputs[i], otp[i], otp[i]);
              }
              filled = true;
            }
          }
          
          // Auto submit if it's 4 or 6 digits
          if (filled && (otp.length === 4 || otp.length === 6)) {
             setTimeout(() => {
               // Try to find verify button
               const btns = Array.from(document.querySelectorAll('button'));
               const verifyBtn = btns.find(b => b.textContent.toLowerCase().includes('verify') || b.textContent.toLowerCase().includes('submit') || b.textContent.toLowerCase().includes('continue') || b.textContent.toLowerCase().includes('confirm'));
               if (verifyBtn && !verifyBtn.disabled) {
                 verifyBtn.click();
               }
             }, 300);
          }
          
          return filled;
        };
      })();
    ''';
    try {
      await controller.evaluateJavascript(source: script);
    } catch (e) {
      debugPrint('⚠️ OTP autofill script inject failed: $e');
    }
  }

  // ───────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final initialUrlStr = AppConfig.webUrl;
    final isInitialCached = _isUrlCached(initialUrlStr);
    
    // If offline and the initial URL is completely uncached, do not even create the WebView.
    final shouldBlockWebViewCreation = !_isOnline && !isInitialCached && _connectivityChecked;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        // Transparent because the Container widget below physically fills the
        // status bar area with _statusBarColor — this bypasses the deprecated
        // Android window.statusBarColor API that is ignored on API 35+.
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: _statusBarIconBrightness,
        // iOS: statusBarBrightness is the inverse of icon brightness.
        statusBarBrightness: _statusBarIconBrightness == Brightness.light
            ? Brightness.dark
            : Brightness.light,
      ),
      child: WillPopScope(
        onWillPop: _onWillPop,
        child: Scaffold(
          body: Stack(
            children: [
              Column(
                children: [
                  // ── Status bar fill ───────────────────────────────────────────
                  // On Android 15+, this paints the transparent OS status bar teal.
                  // On Android 10-14, the OS explicitly paints the native status bar teal,
                  // so this Container becomes a 0-height non-existent spacer because the
                  // shrunk app window starts perfectly below the native status bar.
                  Container(
                    height: (Platform.isAndroid && AppConfig.androidSdkInt < 35)
                        ? 0.0
                        : MediaQuery.of(context).viewPadding.top,
                    color: _statusBarColor,
                  ),
                  // ── Page content (starts below status bar) ────────────────────
                  Expanded(
                    child: !_connectivityChecked
                        ? const SizedBox.shrink()
                        : Stack(
                            children: [
                              if (shouldBlockWebViewCreation)
                                _buildOfflineUI()
                              else
                                InAppWebView(
                                initialUrlRequest: URLRequest(
                                  url: WebUri(AppConfig.webUrl),
                                  cachePolicy: _isOnline 
                                      ? URLRequestCachePolicy.USE_PROTOCOL_CACHE_POLICY 
                                      : URLRequestCachePolicy.RETURN_CACHE_DATA_ELSE_LOAD,
                                ),
                                initialUserScripts:
                                    UnmodifiableListView<UserScript>([
                                  UserScript(
                                    source: """
                            // 1. Polyfill navigator.share to use Flutter native share
                            if (typeof navigator.share === 'undefined' || !navigator.share) {
                              navigator.share = async function(data) {
                                if (window.flutter_inappwebview) {
                                  await window.flutter_inappwebview.callHandler('nativeShare', data);
                                  return;
                                }
                                throw new Error('Share not supported');
                              };
                            }

                            // 2. Intercept clipboard copy as a fallback if the web app doesn't use navigator.share
                            if (navigator.clipboard) {
                              const originalWriteText = navigator.clipboard.writeText;
                              navigator.clipboard.writeText = async function(text) {
                                if (text && typeof text === 'string' && window.flutter_inappwebview) {
                                  // Trigger native share if it looks like a group link
                                  if (text.includes('buytogetherindia.com')) {
                                    window.flutter_inappwebview.callHandler('nativeShare', { url: text });
                                  }
                                }
                                // Always proceed with actual clipboard copy as a fallback
                                return originalWriteText.apply(navigator.clipboard, arguments);
                              };
                            }
                          """,
                                    injectionTime: UserScriptInjectionTime
                                        .AT_DOCUMENT_START,
                                  ),
                                  UserScript(
                                    source: """
                            // 3. Bridge File Chooser natively
                            document.addEventListener('click', function(e) {
                              if (!window.flutter_inappwebview) return;
                              
                              var target = e.target;
                              var btn = target.closest('button') || target;
                              var text = (btn.innerText || '').trim();
                              
                              if (text === 'Take Photo' || text === 'Choose from Gallery') {
                                e.preventDefault();
                                e.stopPropagation();
                                
                                var sourceType = text === 'Take Photo' ? 'camera' : 'gallery';
                                window.flutter_inappwebview.callHandler('debugLog', 'Intercepted ' + text + ' click! Launching native picker: ' + sourceType);
                                
                                // Call native picker
                                window.flutter_inappwebview.callHandler('pickImage', sourceType).then(function(result) {
                                  if (result && result.success) {
                                    window.flutter_inappwebview.callHandler('debugLog', 'Native picker returned image! Assigning to hidden input...');
                                    
                                    // Find the hidden input
                                    var hiddenInput = document.querySelector('input[type="file"].hidden') || document.querySelector('input[type="file"]');
                                    
                                    if (hiddenInput) {
                                      // Convert base64 to Blob, then to File
                                      fetch('data:' + result.mime + ';base64,' + result.base64)
                                        .then(res => res.blob())
                                        .then(blob => {
                                          var file = new File([blob], result.name || 'image.jpg', { type: result.mime });
                                          var dataTransfer = new DataTransfer();
                                          dataTransfer.items.add(file);
                                          
                                          hiddenInput.files = dataTransfer.files;
                                          
                                          // Trigger change event to notify React/website
                                          var event = new Event('change', { bubbles: true });
                                          hiddenInput.dispatchEvent(event);
                                          window.flutter_inappwebview.callHandler('debugLog', 'File successfully assigned to hidden input!');
                                        }).catch(err => {
                                          window.flutter_inappwebview.callHandler('debugLog', 'Fetch Blob Error: ' + err.message);
                                        });
                                    } else {
                                      window.flutter_inappwebview.callHandler('debugLog', 'Error: Hidden file input not found on page!');
                                    }
                                  } else {
                                    window.flutter_inappwebview.callHandler('debugLog', 'Native picker cancelled or failed.');
                                  }
                                });
                              }
                            }, true);
                          """,
                                    injectionTime: UserScriptInjectionTime
                                        .AT_DOCUMENT_END,
                                  )
                                ]),
                                pullToRefreshController:
                                    _pullToRefreshController,
                                initialSettings: InAppWebViewSettings(
                                  cacheEnabled: true,
                                  cacheMode: _isOnline 
                                      ? CacheMode.LOAD_DEFAULT 
                                      : CacheMode.LOAD_CACHE_ELSE_NETWORK,
                                  userAgent:
                                      'Mozilla/5.0 (Linux; Android 13; Pixel 7 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36',
                                  javaScriptEnabled: true,
                                  javaScriptCanOpenWindowsAutomatically: false,
                                  domStorageEnabled: true,
                                  databaseEnabled: true,
                                  mediaPlaybackRequiresUserGesture: false,
                                  allowsInlineMediaPlayback: true,
                                  useOnDownloadStart: true,
                                  geolocationEnabled: true,
                                  supportZoom: true,
                                  builtInZoomControls: true,
                                  displayZoomControls: false,
                                  safeBrowsingEnabled: true,
                                  mixedContentMode: MixedContentMode
                                      .MIXED_CONTENT_ALWAYS_ALLOW,
                                  allowFileAccess: true,
                                  allowFileAccessFromFileURLs: true,
                                  allowUniversalAccessFromFileURLs: true,
                                  useOnLoadResource: true,
                                  useShouldOverrideUrlLoading: true,
                                  verticalScrollBarEnabled: false,
                                  horizontalScrollBarEnabled: false,
                                  disableDefaultErrorPage: true,
                                ),
                                onReceivedError: (controller, request, error) async {
                                  debugPrint('onReceivedError: ${error.description}');
                                  if (request.isForMainFrame ?? true) {
                                    setState(() {
                                      _isLoading = false;
                                      _isInitialLoad = false;
                                      _pageLoadFailed = true;
                                    });
                                  }
                                },
                                onReceivedHttpError: (controller, request, errorResponse) async {
                                  debugPrint('onReceivedHttpError: ${errorResponse.statusCode}');
                                  if (request.isForMainFrame ?? true) {
                                    setState(() {
                                      _isLoading = false;
                                      _isInitialLoad = false;
                                      _pageLoadFailed = true;
                                    });
                                  }
                                },
                                onCreateWindow:
                                    (controller, createWindowRequest) async {
                                  final urlRequest =
                                      createWindowRequest.request;
                                  var url = urlRequest.url;
                                  debugPrint('🪟 onCreateWindow: url=$url');

                                  if (url == null) return false;

                                  // Check for Razorpay UPI app SVG URLs FIRST
                                  // Use stricter check that handles query params
                                  if (url.host.contains('razorpay.com') &&
                                      url.toString().contains('/app/') &&
                                      (url.path.endsWith('.svg') ||
                                          url.toString().contains('.svg'))) {
                                    debugPrint(
                                        '💳 onCreateWindow: Detected Razorpay UPI app SVG, intercepting...');
                                    final upiAppUri =
                                        await _handleRazorpayUPIAppClick(url);
                                    if (upiAppUri != null) {
                                      await _launchExternalUrl(upiAppUri);
                                      return false;
                                    }
                                  }

                                  // Handle non-HTTP schemes
                                  final allowedSchemes = [
                                    'http',
                                    'https',
                                    'file',
                                    'chrome',
                                    'data',
                                    'javascript'
                                  ];
                                  if (!allowedSchemes
                                      .contains(url.scheme.toLowerCase())) {
                                    if (await canLaunchUrl(url)) {
                                      await launchUrl(url,
                                          mode: LaunchMode.externalApplication);
                                      return false;
                                    }
                                  }

                                  if (_shouldLaunchExternally(url)) {
                                    await _launchExternalUrl(url);
                                    return false;
                                  }

                                  controller.loadUrl(urlRequest: urlRequest);
                                  return true;
                                },
                                shouldOverrideUrlLoading:
                                    (controller, navigationAction) async {
                                  final urlRequest = navigationAction.request;
                                  final uri = urlRequest.url;

                                  if (uri == null)
                                    return NavigationActionPolicy.ALLOW;

                                  final urlStr = uri.toString();
                                  if (!_isOnline && !_isUrlCached(urlStr) && !urlStr.startsWith('tel:') && !urlStr.startsWith('mailto:')) {
                                    _showOfflinePopup();
                                    return NavigationActionPolicy.CANCEL;
                                  }

                                  debugPrint('➡️ Navigating: $uri');

                                  // 1. Check for Intent Scheme (Android)
                                  if (uri.scheme.toLowerCase() == 'intent') {
                                    await _handleIntentUrl(uri);
                                    return NavigationActionPolicy.CANCEL;
                                  }

                                  // 2. Check for Phone/Tel Scheme
                                  if (uri.scheme.toLowerCase() == 'tel') {
                                    debugPrint(
                                        '🤖 Detected Intent scheme, launching...');
                                    try {
                                      await launchUrl(uri,
                                          mode: LaunchMode.externalApplication);
                                      return NavigationActionPolicy.CANCEL;
                                    } catch (e) {
                                      debugPrint(
                                          '❌ Failed to launch intent: $e');
                                      // Continue to allow fallback URL processing if handled by webview?
                                      // Usually fallback urls are inside the intent string, complex to parse here.
                                    }
                                  }

                                  // 2. Check for UPI deep links
                                  if (uri.scheme.toLowerCase() == 'upi') {
                                    debugPrint('💳 Detected UPI URL: $uri');
                                    await _launchExternalUrl(uri);
                                    return NavigationActionPolicy.CANCEL;
                                  }

                                  // 3. Check for Razorpay UPI SVG
                                  final upiAppUri =
                                      await _handleRazorpayUPIAppClick(uri);
                                  if (upiAppUri != null) {
                                    await _launchExternalUrl(upiAppUri);
                                    return NavigationActionPolicy.CANCEL;
                                  }

                                  // 4. Handle other non-HTTP schemes
                                  final allowedSchemes = [
                                    'http',
                                    'https',
                                    'file',
                                    'chrome',
                                    'data',
                                    'javascript',
                                    'about'
                                  ];
                                  if (!allowedSchemes
                                      .contains(uri.scheme.toLowerCase())) {
                                    await _launchExternalUrl(uri);
                                    return NavigationActionPolicy.CANCEL;
                                  }

                                  // 5. External launch check
                                  if (_shouldLaunchExternally(uri)) {
                                    await _launchExternalUrl(uri);
                                    return NavigationActionPolicy.CANCEL;
                                  }

                                  return NavigationActionPolicy.ALLOW;
                                },
                                onWebViewCreated: (controller) async {
                                  _forceApplyStatusBarStyle();
                                  _webViewController = controller;

                                  debugPrint('✅ WebView created');

                                  // ── Dynamic Status Bar colour bridge ──────────────
                                  // The JS detector script (injected in onLoadStop)
                                  // calls this handler with the page's top-section colour.
                                  controller.addJavaScriptHandler(
                                    handlerName: 'startOTPListener',
                                    callback: (args) {
                                      _startOTPListener();
                                    },
                                  );

                                  controller.addJavaScriptHandler(
                                    handlerName: 'updateStatusBarColor',
                                    callback: (args) {
                                      if (args.isNotEmpty) {
                                        final colorStr = args[0].toString();

                                        // Prevent white flashes: If the page is currently loading,
                                        // the DOM might briefly be empty/white. We ignore white
                                        // updates during this phase so the status bar retains
                                        // the app theme consistently.
                                        if (_isLoading) {
                                          final s = colorStr
                                              .replaceAll(' ', '')
                                              .toLowerCase();
                                          if (s == 'rgb(255,255,255)' ||
                                              s == '#ffffff') {
                                            return;
                                          }
                                        }

                                        _applyStatusBarColor(colorStr);
                                      }
                                    },
                                  );
                                  // ─────────────────────────────────────────────────

                                  // Native Location Button Click Bridge
                                  controller.addJavaScriptHandler(
                                    handlerName: 'debugLog',
                                    callback: (args) {
                                      debugPrint('🌐 JS LOG: ${args.join(', ')}');
                                    },
                                  );

                                  controller.addJavaScriptHandler(
                                    handlerName: 'pickImage',
                                    callback: (args) async {
                                      try {
                                        final String type = args.isNotEmpty ? args[0].toString() : 'gallery';
                                        debugPrint('📸 JS requested pickImage: $type');
                                        final picker = ImagePicker();
                                        final XFile? file = await picker.pickImage(
                                          source: type == 'camera' ? ImageSource.camera : ImageSource.gallery,
                                          imageQuality: 60,
                                        );
                                        
                                        if (file != null) {
                                          debugPrint('✅ Image picked: ${file.path}');
                                          final bytes = await file.readAsBytes();
                                          final base64String = base64Encode(bytes);
                                          return {
                                            'success': true,
                                            'base64': base64String,
                                            'name': file.name,
                                            'mime': 'image/jpeg'
                                          };
                                        }
                                      } catch (e) {
                                        debugPrint('❌ Error in pickImage handler: $e');
                                      }
                                      return {'success': false};
                                    },
                                  );

                                  controller.addJavaScriptHandler(
                                    handlerName: 'locationButtonClicked',
                                    callback: (args) async {
                                      _locationButtonClickDetected = true;
                                      debugPrint(
                                          '📍 Web location button click detected');

                                      // PROACTIVE: Jump to settings immediately upon click if things are disabled
                                      bool serviceEnabled = await Geolocator
                                          .isLocationServiceEnabled();
                                      if (!serviceEnabled) {
                                        await Geolocator
                                            .openLocationSettings(); // Opens GPS toggle
                                        return;
                                      }

                                      var status =
                                          await Permission.location.status;
                                      if (status.isPermanentlyDenied) {
                                        await openAppSettings(); // Opens Permissions
                                        return;
                                      }

                                      if (status.isDenied) {
                                        status =
                                            await Permission.location.request();
                                        if (!status.isGranted) {
                                          await openAppSettings(); // Forces settings if rejected
                                        }
                                      }
                                    },
                                  );

                                  // Native Google Sign-In Javascript Bridge
                                  controller.addJavaScriptHandler(
                                    handlerName: 'nativeGoogleSignIn',
                                    callback: (args) async {
                                      try {
                                        debugPrint(
                                            '🟢 Triggering Native Google Sign In');

                                        // 1. Show the Native Android Account List
                                        final GoogleSignInAccount? googleUser =
                                            await GoogleSignIn().signIn();
                                        if (googleUser == null) {
                                          debugPrint(
                                              '⚠️ Google Sign-In Cancelled by User');
                                          return {
                                            'success': false,
                                            'cancelled': true,
                                            'error': 'USER_CANCELLED'
                                          };
                                        }

                                        // 2. Get the authentication tokens
                                        final GoogleSignInAuthentication
                                            googleAuth =
                                            await googleUser.authentication;
                                        final idToken = googleAuth.idToken;
                                        final accessToken =
                                            googleAuth.accessToken;

                                        if ((idToken == null ||
                                                idToken.isEmpty) &&
                                            (accessToken == null ||
                                                accessToken.isEmpty)) {
                                          return {
                                            'success': false,
                                            'cancelled': false,
                                            'error': 'SIGN_IN_FAILED',
                                            'message':
                                                'Failed to retrieve Google authentication tokens'
                                          };
                                        }

                                        // 3. Authenticate with Firebase natively (Optional but recommended for full integration)
                                        try {
                                          if (idToken != null &&
                                              idToken.isNotEmpty &&
                                              accessToken != null &&
                                              accessToken.isNotEmpty) {
                                            final OAuthCredential credential =
                                                GoogleAuthProvider.credential(
                                              accessToken: accessToken,
                                              idToken: idToken,
                                            );
                                            await FirebaseAuth.instance
                                                .signInWithCredential(
                                                    credential);
                                            debugPrint(
                                                '✅ Firebase Native Auth Success');
                                          }
                                        } catch (e) {
                                          debugPrint(
                                              '⚠️ Firebase Auth warning: $e');
                                        }

                                        debugPrint(
                                            '✅ Native Google Sign In Success, passing token to web...');

                                        // 4. Return the Google Tokens back to the website Javascript
                                        final Map<String, dynamic> response = {
                                          'success': true,
                                          'email': googleUser.email,
                                          'displayName': googleUser.displayName,
                                          'photoUrl': googleUser.photoUrl
                                        };

                                        if (idToken != null &&
                                            idToken.isNotEmpty) {
                                          response['idToken'] = idToken;
                                        }

                                        if (accessToken != null &&
                                            accessToken.isNotEmpty) {
                                          response['accessToken'] = accessToken;
                                        }

                                        return response;
                                      } catch (error) {
                                        debugPrint(
                                            '❌ Google Sign-In Error: $error');
                                        return {
                                          'success': false,
                                          'cancelled': false,
                                          'error': 'SIGN_IN_FAILED',
                                          'message': error.toString()
                                        };
                                      }
                                    },
                                  );

                                  // Native Google Sign-Out Javascript Bridge
                                  controller.addJavaScriptHandler(
                                    handlerName: 'nativeGoogleSignOut',
                                    callback: (args) async {
                                      try {
                                        debugPrint(
                                            '🟢 Triggering Native Google Sign Out');
                                        await GoogleSignIn().signOut();
                                        await FirebaseAuth.instance.signOut();
                                        return {'success': true};
                                      } catch (error) {
                                        debugPrint(
                                            '❌ Google Sign-Out Error: $error');
                                        return {
                                          'success': false,
                                          'error': error.toString()
                                        };
                                      }
                                    },
                                  );

                                  // Add JavaScript handler to open camera directly
                                  controller.addJavaScriptHandler(
                                    handlerName: 'openCamera',
                                    callback: (args) async {
                                      try {
                                        // Because CAMERA is declared in AndroidManifest.xml, image_picker
                                        // requires it to be granted at runtime before pickImage(camera)
                                        // will return a photo — and it does NOT request it for us.
                                        var status =
                                            await Permission.camera.status;
                                        if (!status.isGranted) {
                                          status =
                                              await Permission.camera.request();
                                        }
                                        if (!status.isGranted) {
                                          debugPrint(
                                              '⚠️ Camera permission not granted');
                                          if (status.isPermanentlyDenied) {
                                            await openAppSettings();
                                          }
                                          return {
                                            'success': false,
                                            'error': 'CAMERA_PERMISSION_DENIED',
                                          };
                                        }

                                        // Open camera using image_picker
                                        final ImagePicker picker =
                                            ImagePicker();
                                        final XFile? image =
                                            await picker.pickImage(
                                          source: ImageSource.camera,
                                          imageQuality: 80,
                                        );

                                        if (image != null) {
                                          // Read file as base64
                                          final bytes =
                                              await image.readAsBytes();
                                          final base64String =
                                              base64Encode(bytes);

                                          // Return to JavaScript
                                          return {
                                            'success': true,
                                            'base64': base64String,
                                            'mimeType': 'image/jpeg',
                                            'fileName': image.name,
                                          };
                                        }

                                        // image == null → user cancelled the camera.
                                        return {
                                          'success': false,
                                          'cancelled': true
                                        };
                                      } catch (e) {
                                        debugPrint(
                                            '❌ Error in openCamera handler: $e');
                                        return {
                                          'success': false,
                                          'error': e.toString()
                                        };
                                      }
                                    },
                                  );

                                  // Add JavaScript handler to receive phone number from website
                                  controller.addJavaScriptHandler(
                                    handlerName: 'savePhoneNumber',
                                    callback: (args) async {
                                      if (args.isNotEmpty) {
                                        final phoneNumber = args[0].toString();
                                        debugPrint(
                                          '📱 Phone number received from website: $phoneNumber',
                                        );
                                        // Clean phone number (remove any non-digits, remove +91 prefix if present)
                                        String cleanedPhone =
                                            phoneNumber.replaceAll(
                                          RegExp(r'[^\d]'),
                                          '',
                                        );
                                        if (cleanedPhone.length > 10 &&
                                            cleanedPhone.startsWith('91')) {
                                          cleanedPhone =
                                              cleanedPhone.substring(2);
                                        }
                                        if (cleanedPhone.length == 10) {
                                          await PrefsUtil.setPhoneNumber(
                                              cleanedPhone);
                                          debugPrint(
                                            '✅ Phone number saved: $cleanedPhone',
                                          );
                                          // Save FCM token now that we have phone number
                                          await _saveFCMTokenIfPhoneAvailable();
                                        } else {
                                          debugPrint(
                                            '⚠️ Invalid phone number format: $cleanedPhone',
                                          );
                                        }
                                      }
                                    },
                                  );

                                  // Add nativeShare handler
                                  controller.addJavaScriptHandler(
                                    handlerName: 'nativeShare',
                                    callback: (arguments) async {
                                      return _handleNativeShare(arguments);
                                    },
                                  );

                                  controller.addJavaScriptHandler(
                                    handlerName: 'showOfflinePopup',
                                    callback: (args) {
                                      debugPrint('🚫 SPA offline blank screen caught -> popup');
                                      _showOfflinePopup();
                                    },
                                  );
                                  controller.addJavaScriptHandler(
                                    handlerName: 'showOfflineFullScreen',
                                    callback: (args) {
                                      debugPrint('🚫 SPA offline blank screen caught -> full screen');
                                      if (mounted) {
                                        setState(() {
                                          _pageLoadFailed = true;
                                        });
                                      }
                                    },
                                  );
                                },
                                onLoadStart: (controller, url) {
                                  _forceApplyStatusBarStyle();
                                  setState(() {
                                    _isLoading = true;
                                    _pageLoadFailed = false;
                                    _phoneListenerInjected = false;
                                    _linkInterceptorInjected = false;
                                  });
                                  debugPrint('🌐 Loading started: $url');
                                },
                                onLoadStop: (controller, url) async {
                                  if (url != null) {
                                    _cachedUrls.add(url.toString());
                                    _cachedUrls.add(url.toString().split('?').first);
                                    SharedPreferences.getInstance().then((prefs) {
                                      prefs.setStringList('cached_urls', _cachedUrls.toList());
                                    });
                                  }
                                  
                                  _forceApplyStatusBarStyle();
                                  setState(() {
                                    _isLoading = false;
                                    _isInitialLoad = false;
                                    _pullToRefreshController.endRefreshing();
                                    _loadingProgress = 1.0;
                                  });
                                  debugPrint('✅ Loading finished: $url');
                                  await _injectPhoneCaptureScript(controller);
                                  await _injectLinkInterceptorScript(
                                      controller);
                                  await _injectApiInterceptorScript(controller);
                                  await _injectOTPAutofillScript(controller);
                                  // Detect the page's top-section colour and adapt the status bar.
                                  await _injectStatusBarColorDetector(
                                      controller);

                                  // Fire ready event for website to detect bridge
                                  await controller.evaluateJavascript(
                                    source: '''
                            window.__flutter_inappwebview_ready__ = true;
                            window.dispatchEvent(new Event('flutterInAppWebViewPlatformReady'));
                          ''',
                                  );

                                  // Restart OTP listener state on navigation
                                  await controller.evaluateJavascript(
                                      source:
                                          'if (window.__otpInjectorReady) { window.__otpInjectorReady = false; }');

                                  // Fallback: If offline and the page rendered completely blank (SPA failure)
                                  if (!_isOnline) {
                                    Future.delayed(const Duration(milliseconds: 800), () async {
                                      if (mounted && _webViewController != null && !_isLoading) {
                                        try {
                                          final text = await _webViewController!.evaluateJavascript(
                                            source: "document.body ? document.body.innerText.trim() : ''"
                                          );
                                          final html = await _webViewController!.evaluateJavascript(
                                            source: "document.body ? document.body.innerHTML.trim() : ''"
                                          );
                                          
                                          if ((text == null || text.toString().isEmpty) && 
                                              (html == null || html.toString().length < 100)) {
                                            debugPrint('⚠️ Detected blank screen while offline, forcing offline UI');
                                            final canGoBack = await controller.canGoBack();
                                            if (canGoBack) {
                                              await controller.goBack();
                                              _showOfflinePopup();
                                            } else {
                                              setState(() {
                                                _pageLoadFailed = true;
                                              });
                                            }
                                          }
                                        } catch (e) {
                                          debugPrint('Error checking for blank page: $e');
                                        }
                                      }
                                    });
                                  }
                                },
                                onProgressChanged: (controller, progress) {
                                  if (progress == 100) {
                                    _forceApplyStatusBarStyle();
                                  }
                                  setState(() {
                                    _loadingProgress = progress / 100;
                                    if (progress >= 100) {
                                      _isLoading = false;
                                      _isInitialLoad = false;
                                    }
                                  });
                                  debugPrint('📊 Loading progress: $progress%');
                                },
                                onLoadError: (controller, url, code, message) async {
                                  _pullToRefreshController.endRefreshing();
                                  debugPrint('❌ Load error: $message (code: $code)');
                                  setState(() {
                                    _isLoading = false;
                                    _isInitialLoad = false;
                                    _pageLoadFailed = true;
                                  });
                                },
                                onLoadHttpError: (controller, url, statusCode, description) async {
                                  _pullToRefreshController.endRefreshing();
                                  debugPrint('❌ Load HTTP error: $statusCode $description');
                                  setState(() {
                                    _isLoading = false;
                                    _isInitialLoad = false;
                                    _pageLoadFailed = true;
                                  });
                                },
                                onGeolocationPermissionsShowPrompt:
                                    (controller, origin) async {
                                  return GeolocationPermissionShowPromptResponse(
                                      origin: origin,
                                      allow: true,
                                      retain: true);
                                },
                                onPermissionRequest:
                                    (controller, request) async {
                                  debugPrint(
                                      '🔒 Permission requested: ${request.resources}');

                                  final resources = request.resources;
                                  if (resources.contains(
                                      PermissionResourceType.CAMERA)) {
                                    final status =
                                        await Permission.camera.request();
                                    if (!status.isGranted) {
                                      return PermissionResponse(
                                        resources: resources,
                                        action: PermissionResponseAction.DENY,
                                      );
                                    }
                                  }

                                  if (resources.contains(
                                      PermissionResourceType.MICROPHONE)) {
                                    final status =
                                        await Permission.microphone.request();
                                    if (!status.isGranted) {
                                      return PermissionResponse(
                                        resources: resources,
                                        action: PermissionResponseAction.DENY,
                                      );
                                    }
                                  }

                                  return PermissionResponse(
                                    resources: resources,
                                    action: PermissionResponseAction.GRANT,
                                  );
                                },
                                onConsoleMessage: (controller, consoleMessage) {
                                  debugPrint(
                                      '🌐 JS Console: ${consoleMessage.messageLevel}: ${consoleMessage.message}');
                                },
                                onDownloadStartRequest:
                                    (controller, downloadStartRequest) async {
                                  try {
                                    final url =
                                        downloadStartRequest.url.toString();
                                    final suggestedFilename =
                                        downloadStartRequest.suggestedFilename;
                                    final mimeType =
                                        downloadStartRequest.mimeType;
                                    final contentDisposition =
                                        downloadStartRequest.contentDisposition;

                                    debugPrint('📥 Download requested: $url');
                                    debugPrint(
                                        '📄 Suggested filename: $suggestedFilename');
                                    debugPrint('📋 MIME type: $mimeType');
                                    debugPrint(
                                        '📋 Content-Disposition: $contentDisposition');

                                    // Handle blob URLs - they need to be extracted via JavaScript
                                    if (url.startsWith('blob:')) {
                                      debugPrint(
                                          '🔵 Blob URL detected, extracting blob data...');
                                      await _handleBlobDownload(
                                        controller: controller,
                                        blobUrl: url,
                                        suggestedFilename:
                                            suggestedFilename ?? 'receipt.pdf',
                                        mimeType: mimeType ?? 'application/pdf',
                                        isReceiptDownload: true,
                                      );
                                      return;
                                    }

                                    // Check if it's a receipt download
                                    final isReceiptDownload =
                                        url.contains('receipt') ||
                                            url.contains('download-receipt') ||
                                            url.contains('invoice') ||
                                            (suggestedFilename != null &&
                                                (suggestedFilename
                                                        .toLowerCase()
                                                        .contains('receipt') ||
                                                    suggestedFilename
                                                        .toLowerCase()
                                                        .contains('invoice')));

                                    if (!mounted) return;

                                    // For Android 10+, app-specific directories don't require permission
                                    // Only request permission if we need public Downloads folder
                                    // But we'll try public Downloads first, fallback to app-specific if needed
                                    bool hasPermission = false;
                                    bool canDownload = true;

                                    if (isReceiptDownload) {
                                      // For receipts, try to get permission for public Downloads
                                      hasPermission =
                                          await PermissionHandlerUtil
                                              .checkStoragePermission();
                                      if (!hasPermission) {
                                        final granted =
                                            await PermissionHandlerUtil
                                                .requestStoragePermission();
                                        if (!granted) {
                                          // Permission denied, but we can still download to app-specific folder
                                          debugPrint(
                                              '⚠️ Permission denied, will use app-specific Downloads folder');
                                          hasPermission = false;
                                          canDownload =
                                              true; // Still allow download to app folder
                                        } else {
                                          hasPermission = true;
                                        }
                                      } else {
                                        hasPermission = true;
                                      }
                                    } else {
                                      // For other files, app-specific directory doesn't need permission
                                      canDownload = true;
                                    }

                                    if (!canDownload) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                                'Cannot download file. Please check storage permissions in app settings.'),
                                            backgroundColor: Colors.orange,
                                            duration: Duration(seconds: 3),
                                          ),
                                        );
                                      }
                                      return;
                                    }

                                    // Show download progress
                                    if (mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Row(
                                            children: [
                                              const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  valueColor:
                                                      AlwaysStoppedAnimation<
                                                          Color>(Colors.white),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  isReceiptDownload
                                                      ? 'Downloading receipt...'
                                                      : 'Downloading file...',
                                                  style: const TextStyle(
                                                      color: Colors.white),
                                                ),
                                              ),
                                            ],
                                          ),
                                          backgroundColor: Colors.blue,
                                          duration: const Duration(seconds: 2),
                                        ),
                                      );
                                    }

                                    // Download the file
                                    // For Android 10+, app-specific directories don't require permission
                                    // Try public Downloads for receipts if permission granted, otherwise use app-specific
                                    final downloadService = DownloadService();
                                    DownloadResult result;

                                    if (isReceiptDownload && hasPermission) {
                                      // Try public Downloads folder first
                                      debugPrint(
                                          '📥 Attempting to download receipt to public Downloads folder...');
                                      result =
                                          await downloadService.downloadFile(
                                        url: url,
                                        contentDisposition: contentDisposition,
                                        context: context,
                                        usePublicDownloads:
                                            true, // Try public Downloads
                                        onProgress: (received, total) {
                                          if (total > 0) {
                                            final progress =
                                                (received / total * 100)
                                                    .toStringAsFixed(1);
                                            debugPrint(
                                                '📥 Download progress: $progress%');
                                          }
                                        },
                                      );

                                      // If public Downloads failed, fallback to app-specific folder
                                      if (!result.success) {
                                        debugPrint(
                                            '⚠️ Public Downloads failed, using app-specific folder...');
                                        result =
                                            await downloadService.downloadFile(
                                          url: url,
                                          contentDisposition:
                                              contentDisposition,
                                          context: context,
                                          usePublicDownloads:
                                              false, // Use app-specific folder (no permission needed)
                                          onProgress: (received, total) {
                                            if (total > 0) {
                                              final progress =
                                                  (received / total * 100)
                                                      .toStringAsFixed(1);
                                              debugPrint(
                                                  '📥 Download progress: $progress%');
                                            }
                                          },
                                        );
                                      }
                                    } else {
                                      // Use app-specific folder (no permission needed for Android 10+)
                                      debugPrint(
                                          '📥 Downloading to app-specific Downloads folder (no permission needed)...');
                                      result =
                                          await downloadService.downloadFile(
                                        url: url,
                                        contentDisposition: contentDisposition,
                                        context: context,
                                        usePublicDownloads:
                                            false, // Use app-specific folder
                                        onProgress: (received, total) {
                                          if (total > 0) {
                                            final progress =
                                                (received / total * 100)
                                                    .toStringAsFixed(1);
                                            debugPrint(
                                                '📥 Download progress: $progress%');
                                          }
                                        },
                                      );
                                    }

                                    if (!mounted) return;

                                    if (result.success &&
                                        result.filePath != null) {
                                      // Show success message
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  const Icon(Icons.check_circle,
                                                      color: Colors.white),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(
                                                      isReceiptDownload
                                                          ? 'Receipt saved to Downloads'
                                                          : 'File saved to Downloads',
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              if (result.filename != null) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  result.filename!,
                                                  style: const TextStyle(
                                                    color: Colors.white70,
                                                    fontSize: 12,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ],
                                          ),
                                          backgroundColor: Colors.green,
                                          duration: const Duration(seconds: 4),
                                          behavior: SnackBarBehavior.floating,
                                          action: SnackBarAction(
                                            label: 'OPEN',
                                            textColor: Colors.white,
                                            onPressed: () async {
                                              if (result.filePath != null) {
                                                await downloadService
                                                    .openFile(result.filePath!);
                                              }
                                            },
                                          ),
                                        ),
                                      );
                                      debugPrint(
                                          '✅ Download successful: ${result.filePath}');
                                    } else {
                                      // Show error message
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            result.error ?? 'Download failed',
                                            style: const TextStyle(
                                                color: Colors.white),
                                          ),
                                          backgroundColor: Colors.red,
                                          duration: const Duration(seconds: 3),
                                        ),
                                      );
                                      debugPrint(
                                          '❌ Download failed: ${result.error}');
                                    }
                                  } catch (e) {
                                    debugPrint('❌ Error handling download: $e');
                                    if (mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text('Download failed: $e'),
                                          backgroundColor: Colors.red,
                                          duration: const Duration(seconds: 3),
                                        ),
                                      );
                                    }
                                  }
                                },
                              ),
                              if (!shouldBlockWebViewCreation && _pageLoadFailed)
                                _buildOfflineUI(),
                                // Loading indicator overlay - only show when loading
                                if (!shouldBlockWebViewCreation &&
                                    _isLoading &&
                                    !_pageLoadFailed &&
                                    !(_isInitialLoad ||
                                        !_splashMinDurationElapsed))
                                Container(
                                  color: Colors.white.withOpacity(0.9),
                                  child: Center(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        CircularProgressIndicator(
                                          value: _loadingProgress < 1.0 &&
                                                  _loadingProgress > 0
                                              ? _loadingProgress
                                              : null,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  AppConfig.primaryColor),
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          'Loading...',
                                          style: TextStyle(
                                            fontSize: 16,
                                            color: AppConfig.primaryColor,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ), // closes Expanded
                ], // closes Column children list
              ), // closes Column
              // ── Splash Screen (Full Screen Overlay) ───────────
              if (_isInitialLoad || !_splashMinDurationElapsed)
                const Positioned.fill(
                  child: SplashScreen(),
                ),
            ], // closes Stack children
          ), // closes Stack (Scaffold body)
        ), // closes Scaffold
      ), // closes WillPopScope
    ); // closes AnnotatedRegion return
  }

  Widget _buildOfflineUI() {
    return Positioned.fill(
      child: Container(
        color: Colors.white,
        width: double.infinity,
        height: double.infinity,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 80,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 20),
            const Text(
              'No Internet Connection',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 10),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                'Please turn on your internet connection to load this page.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.black54,
                ),
              ),
            ),
            const SizedBox(height: 30),
            ElevatedButton.icon(
              onPressed: () {
                setState(() {
                  _pageLoadFailed = false;
                  _isLoading = true;
                });
                _retryLoad();
              },
              icon: const Icon(Icons.refresh, color: Colors.white),
              label: const Text('Try Again', style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppConfig.primaryColor,
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showOfflinePopup() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: const [
            Icon(Icons.wifi_off, color: Colors.white),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                "No internet connection. Please check your internet and try again.",
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF8E4692),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  Widget _buildSourceOption({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: AppConfig.primaryColor.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: 30,
              color: AppConfig.primaryColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
