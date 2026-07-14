import 'package:flutter/services.dart';

/// ScreenshotService — uses FLAG_SECURE (Android) via a native MethodChannel
/// to block screenshots + screen recording in the app.
///
/// Implementation: the MainActivity.kt on Android sets/clears
/// `WindowManager.LayoutParams.FLAG_SECURE` on the activity's window.
/// This blocks screenshots, screen recording, and shows a black
/// rectangle in the recent-apps preview.
class ScreenshotService {
  static const _channel = MethodChannel('io.send.secure/screenshot');
  static bool _secure = false;

  static Future<void> enableSecure() async {
    if (_secure) return;
    try {
      await _channel.invokeMethod('enableSecure');
      _secure = true;
    } catch (_) {}
  }

  static Future<void> disableSecure() async {
    if (!_secure) return;
    try {
      await _channel.invokeMethod('disableSecure');
      _secure = false;
    } catch (_) {}
  }

  static bool get isSecure => _secure;
}
