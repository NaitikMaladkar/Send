import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart'
    hide NotificationVisibility;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Push-notification delivery without Firebase.
///
/// Strategy:
///   1. A long-running foreground service (Android) keeps the app process
///      alive while in background. The Dart isolate polls `fetch_inbox()`
///      every 30 seconds and surfaces new rows via local notifications.
///   2. The notification body shows "New encrypted message" (no plaintext —
///      see Privacy policy).
class NotificationService {
  static final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const init = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _local.initialize(init);

    const channel = AndroidNotificationChannel(
      'send.messages',
      'Send · Messages',
      description: 'New encrypted messages',
      importance: Importance.high,
      enableVibration: true,
      playSound: true,
    );
    await _local
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    const frChannel = AndroidNotificationChannel(
      'send.friends',
      'Send · Friend requests',
      description: 'Incoming friend requests',
      importance: Importance.defaultImportance,
    );
    await _local
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(frChannel);
  }

  static Future<void> showIncomingMessage({String? preview}) async {
    await _local.show(
      DateTime.now().millisecondsSinceEpoch % 0x7fffffff,
      'Send · New message',
      preview ?? 'Tap to view',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'send.messages',
          'Send · Messages',
          priority: Priority.high,
          importance: Importance.high,
          icon: '@mipmap/ic_launcher',
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.private,
        ),
      ),
    );
  }

  static Future<void> showFriendRequest({String? fromId}) async {
    final body = fromId != null
        ? 'From ${fromId.substring(0, 8)}…'
        : 'New friend request';
    await _local.show(
      DateTime.now().millisecondsSinceEpoch % 0x7fffffff,
      'Send · Friend request',
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'send.friends',
          'Send · Friend requests',
          priority: Priority.defaultPriority,
          importance: Importance.defaultImportance,
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );
  }

  /// Initialize the foreground-task subsystem.
  static Future<void> initForegroundTask() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'send.foreground',
        channelName: 'Send · Service',
        channelDescription: 'Keeps your encrypted inbox connected in background',
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<void> startForeground() async {
    if (Platform.isAndroid) {
      await FlutterForegroundTask.startService(
        notificationTitle: 'Send is connected',
        notificationText: 'Listening for encrypted messages',
      );
    }
  }

  static Future<void> stopForeground() async {
    if (Platform.isAndroid) {
      await FlutterForegroundTask.stopService();
    }
  }
}
