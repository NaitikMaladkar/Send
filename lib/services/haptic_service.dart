import 'package:flutter/services.dart';

/// HapticService — wraps HapticFeedback with semantic, throttled calls.
class HapticService {
  static bool _enabled = true;

  static void setEnabled(bool v) => _enabled = v;

  static Future<void> light() async {
    if (!_enabled) return;
    await HapticFeedback.lightImpact();
  }

  static Future<void> medium() async {
    if (!_enabled) return;
    await HapticFeedback.mediumImpact();
  }

  static Future<void> heavy() async {
    if (!_enabled) return;
    await HapticFeedback.heavyImpact();
  }

  static Future<void> selection() async {
    if (!_enabled) return;
    await HapticFeedback.selectionClick();
  }

  static Future<void> sent() async => light();

  static Future<void> delivered() async => selection();

  static Future<void> error() async => heavy();

  static Future<void> longPress() async => medium();
}
