import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:fluxer_app/core/gateway/background/background_gateway_task_entrypoint.dart';

/// Main-isolate-facing facade for the background gateway foreground service.
/// Android-only; every method is a no-op elsewhere.
class BackgroundGatewayService {
  BackgroundGatewayService._();
  static final BackgroundGatewayService instance = BackgroundGatewayService._();

  static const String _channelId = 'fluxer_background_gateway';
  static const String _channelName = 'Background connection';
  static const String _channelDescription =
      'Keeps Fluxer connected in the background so notifications keep working.';

  bool _initialized = false;

  bool get _isSupported => !kIsWeb && Platform.isAndroid;

  void _ensureInitialized() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _channelId,
        channelName: _channelName,
        channelDescription: _channelDescription,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWifiLock: true,
      ),
    );
  }

  Future<bool> isRunning() async {
    if (!_isSupported) {
      return false;
    }
    return FlutterForegroundTask.isRunningService;
  }

  Future<void> start() async {
    if (!_isSupported) {
      return;
    }
    if (await isRunning()) {
      return;
    }
    _ensureInitialized();
    await FlutterForegroundTask.startService(
      serviceId: 8420,
      notificationTitle: 'Fluxer',
      notificationText: 'Staying connected in the background',
      callback: backgroundGatewayTaskEntrypoint,
    );
  }

  Future<void> stop() async {
    if (!_isSupported) {
      return;
    }
    if (!await isRunning()) {
      return;
    }
    await FlutterForegroundTask.stopService();
  }
}
