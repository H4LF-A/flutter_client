import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:fluxer_app/core/gateway/background/background_gateway_message_mapper.dart';
import 'package:fluxer_app/core/gateway/background/background_gateway_session_snapshot.dart';
import 'package:fluxer_app/core/gateway/background/background_gateway_unread_sync.dart';
import 'package:fluxer_app/core/push/local_push_notifications.dart';
import 'package:fluxer_app/features/auth/data/auth_token_storage.dart';
import 'package:fluxer_dart/gateway.dart';

/// Runs entirely in the foreground-service's own headless isolate. Opens a
/// second, minimal GatewayConnection (no Riverpod, no Drift) just to catch
/// MESSAGE_CREATE events and turn them into local notifications. Runs
/// continuously alongside the main isolate's own connection whenever the
/// feature is enabled — see BackgroundGatewayPreference for why this isn't
/// gated on foreground/background state. Notifications are suppressed while
/// [_isAppForeground] is true to avoid double-notifying for a message
/// already visible on screen.
class BackgroundGatewayTaskHandler extends TaskHandler {
  GatewayConnection? _connection;
  StreamSubscription<GatewayEvent>? _subscription;
  StreamSubscription<GatewayEvent>? _ackSubscription;
  StreamSubscription<GatewayEvent>? _readySubscription;
  bool _unreadSyncInFlight = false;
  // Assume foreground until told otherwise: the service now runs
  // continuously (including while the app is open), and the main isolate's
  // foreground-state sync message may not have arrived yet right after
  // start. Defaulting to "foreground" means the worst case on a race is a
  // briefly missed notification, not an annoying duplicate for a message
  // already visible on screen.
  bool _isAppForeground = true;
  // The connection stays alive continuously once started (see class doc),
  // so a fresh ReadyEvent — the only trigger for the unread-sync pass — only
  // ever happens once, right when the service starts. Since the service
  // always starts as part of app launch, that one opportunity always lands
  // while the app is foreground. Dropping it there (like the live
  // MessageCreateEvent path does) would mean the sync pass effectively never
  // runs. Defer it instead: hold onto the event and run the sync as soon as
  // the app actually backgrounds.
  ReadyEvent? _pendingUnreadSyncReadyEvent;
  String? _pendingUnreadSyncUserId;
  String? _pendingUnreadSyncApiBaseUrl;
  String? _pendingUnreadSyncToken;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Never let onStart throw uncaught: an unhandled exception here would
    // silently kill the isolate/service (and its notification) with nothing
    // for the user to see. Surface the actual failure in the persistent
    // notification text instead, so a real device report is diagnosable
    // without adb logcat access.
    try {
      WidgetsFlutterBinding.ensureInitialized();
      final BackgroundGatewaySessionSnapshot? snapshot =
          await readBackgroundGatewaySessionSnapshot();
      if (snapshot == null) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Fluxer',
          notificationText: 'Not connected: no saved session',
        );
        return;
      }
      final String? token = await SecureAuthTokenStorage().readToken(
        snapshot.userId,
      );
      if (token == null || token.isEmpty) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Fluxer',
          notificationText: 'Not connected: no saved login token',
        );
        return;
      }
      await LocalPushNotifications().ensureInitialized();
      final GatewayConnection connection = GatewayConnection(
        token: token,
        dio: Dio(BaseOptions(baseUrl: snapshot.apiBaseUrl)),
        gatewayUrl: snapshot.gatewayUrl,
        properties: GatewayIdentifyProperties(
          os: Platform.operatingSystem,
          browser: 'fluxer_app_background',
          device: Platform.operatingSystem,
          osVersion: Platform.operatingSystemVersion,
          locale: Platform.localeName,
          browserVersion: '1.0.0',
          mobile: true,
        ),
      );
      _connection = connection;
      _subscription = connection.events
          .where((GatewayEvent event) => event is MessageCreateEvent)
          .cast<MessageCreateEvent>()
          .listen((MessageCreateEvent event) {
        final message = mapMessageCreateEventToPushMessage(
          event,
          currentUserId: snapshot.userId,
        );
        if (message != null && !_isAppForeground) {
          unawaited(LocalPushNotifications().showPushMessage(message));
        }
      });
      _ackSubscription = connection.events
          .where((GatewayEvent event) => event is MessageAckEvent)
          .cast<MessageAckEvent>()
          .listen((MessageAckEvent event) {
        // Unconditional: cheap and idempotent even if the app is
        // foregrounded, and covers the case where the ack came from
        // another device/session reading the channel elsewhere.
        unawaited(LocalPushNotifications().cancelForChannel(event.channelId));
      });
      _readySubscription = connection.events
          .where((GatewayEvent event) => event is ReadyEvent)
          .cast<ReadyEvent>()
          .listen((ReadyEvent readyEvent) {
        if (_isAppForeground) {
          _pendingUnreadSyncReadyEvent = readyEvent;
          _pendingUnreadSyncUserId = snapshot.userId;
          _pendingUnreadSyncApiBaseUrl = snapshot.apiBaseUrl;
          _pendingUnreadSyncToken = token;
          return;
        }
        _runUnreadSync(
          event: readyEvent,
          currentUserId: snapshot.userId,
          apiBaseUrl: snapshot.apiBaseUrl,
          token: token,
        );
      });
      connection.stateChanges.listen((GatewayState state) {
        unawaited(
          FlutterForegroundTask.updateService(
            notificationTitle: 'Fluxer',
            notificationText: switch (state) {
              GatewayState.connected => 'Staying connected in the background',
              GatewayState.connecting => 'Connecting…',
              GatewayState.reconnecting => 'Reconnecting…',
              GatewayState.disconnected => 'Disconnected',
              GatewayState.failed => 'Connection failed',
            },
          ),
        );
      });
      await connection.connect();
    } on Object catch (error) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Fluxer',
        notificationText: 'Error: $error',
      );
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _subscription?.cancel();
    _subscription = null;
    await _ackSubscription?.cancel();
    _ackSubscription = null;
    await _readySubscription?.cancel();
    _readySubscription = null;
    await _connection?.dispose();
    _connection = null;
  }

  @override
  void onReceiveData(Object data) {
    if (data is! bool) {
      return;
    }
    _isAppForeground = data;
    if (data) {
      return;
    }
    final ReadyEvent? pending = _pendingUnreadSyncReadyEvent;
    final String? userId = _pendingUnreadSyncUserId;
    final String? apiBaseUrl = _pendingUnreadSyncApiBaseUrl;
    final String? token = _pendingUnreadSyncToken;
    if (pending == null || userId == null || apiBaseUrl == null || token == null) {
      return;
    }
    _pendingUnreadSyncReadyEvent = null;
    _pendingUnreadSyncUserId = null;
    _pendingUnreadSyncApiBaseUrl = null;
    _pendingUnreadSyncToken = null;
    _runUnreadSync(
      event: pending,
      currentUserId: userId,
      apiBaseUrl: apiBaseUrl,
      token: token,
    );
  }

  void _runUnreadSync({
    required ReadyEvent event,
    required String currentUserId,
    required String apiBaseUrl,
    required String token,
  }) {
    if (_unreadSyncInFlight) {
      return;
    }
    _unreadSyncInFlight = true;
    unawaited(
      runBackgroundGatewayUnreadSync(
        event: event,
        currentUserId: currentUserId,
        apiBaseUrl: apiBaseUrl,
        token: token,
        isAppForeground: false,
      ).whenComplete(() => _unreadSyncInFlight = false),
    );
  }

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {}

  @override
  void onNotificationDismissed() {}
}
