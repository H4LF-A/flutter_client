import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:fluxer_app/core/badge/push_badge_count_parser.dart';
import 'package:fluxer_app/core/push/push_message.dart';
import 'package:fluxer_app/core/push/push_notification_ids.dart'
    show
        kLocalNotificationMessageIdKey,
        pushMessageNotificationId,
        pushNotificationCancelIds;
import 'package:fluxer_app/core/push/push_notification_payload.dart';
import 'package:fluxer_app/core/push/push_notification_permission.dart';

final class LocalPushNotifications {
  factory LocalPushNotifications() => _instance;
  LocalPushNotifications._();
  static final LocalPushNotifications _instance = LocalPushNotifications._();

  static const String _channelId = 'fluxer_default_push';
  static const String _channelName = 'Fluxer';
  static const String _channelDescription = 'Messages and alerts';
  static const String _androidNotificationIcon =
      '@drawable/fluxer_logo_monochrome';

  static const int _maxGroupSummaryLines = 8;
  // Shared by every conversation notification plus the app summary, so
  // Android bundles everything under one master "Fluxer" heading — the
  // per-conversation notifications are the group's children, not each other.
  static const String _appGroupKey = 'fluxer_notifications_group';
  static final int _appSummaryNotificationId = pushMessageNotificationId(
    'app_summary',
  );

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  void Function(String? payloadJson)? _onNotificationTap;
  // One entry per conversation (channel/DM): a single notification per chat
  // that gets updated in place as messages arrive, rather than one
  // notification per message.
  final Map<String, _ConversationState> _conversationState =
      <String, _ConversationState>{};
  final Dio _avatarDio = Dio();
  // Small in-memory cache, scoped to this singleton's process lifetime -
  // avoids re-downloading the same sender's avatar for every message in a
  // fast-moving conversation. Not persisted to disk: this app instance
  // (background isolate or foreground) is short-lived enough per wake that a
  // full disk cache isn't worth the added complexity here.
  static const int _maxAvatarCacheEntries = 64;
  final Map<String, Uint8List?> _avatarCache = <String, Uint8List?>{};

  Future<Uint8List?> _fetchAvatarBytes(String? url) async {
    if (url == null || url.isEmpty) {
      return null;
    }
    if (_avatarCache.containsKey(url)) {
      return _avatarCache[url];
    }
    Uint8List? bytes;
    try {
      final Response<List<int>> response = await _avatarDio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final List<int>? data = response.data;
      if (data != null) {
        bytes = Uint8List.fromList(data);
      }
    } on Object catch (e) {
      if (kDebugMode) {
        debugPrint('[LocalPushNotifications] avatar fetch failed: $e');
      }
    }
    if (_avatarCache.length >= _maxAvatarCacheEntries) {
      _avatarCache.remove(_avatarCache.keys.first);
    }
    _avatarCache[url] = bytes;
    return bytes;
  }

  Future<bool> ensureInitialized({
    void Function(String? payloadJson)? onNotificationTap,
  }) async {
    if (onNotificationTap != null) {
      _onNotificationTap = onNotificationTap;
    }
    if (kIsWeb) {
      return true;
    }
    if (_initialized) {
      return true;
    }
    try {
      const DarwinInitializationSettings darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      final InitializationSettings settings = InitializationSettings(
        android: defaultTargetPlatform == TargetPlatform.android
            ? const AndroidInitializationSettings(_androidNotificationIcon)
            : null,
        iOS: defaultTargetPlatform == TargetPlatform.iOS ? darwin : null,
        macOS: defaultTargetPlatform == TargetPlatform.macOS ? darwin : null,
        linux: defaultTargetPlatform == TargetPlatform.linux
            ? const LinuxInitializationSettings(defaultActionName: 'Open')
            : null,
      );
      final bool? ok = await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: _onNotificationResponse,
      );
      _initialized = ok ?? false;
      if (_initialized) {
        await _handleLaunchNotification();
      }
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _ensureAndroidChannel();
      }
    } on Object {
      _initialized = false;
      return false;
    }
    return _initialized;
  }

  Future<void> _ensureAndroidChannel() async {
    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) {
      return;
    }
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDescription,
      importance: Importance.high,
    );
    await android.createNotificationChannel(channel);
  }

  Future<void> requestDisplayPermission() async {
    await requestPushNotificationPermission();
  }

  void _onNotificationResponse(NotificationResponse response) {
    _onNotificationTap?.call(response.payload);
  }

  Future<void> _handleLaunchNotification() async {
    final NotificationAppLaunchDetails? details = await _plugin
        .getNotificationAppLaunchDetails();
    if (details == null ||
        !details.didNotificationLaunchApp ||
        details.notificationResponse == null) {
      return;
    }
    _onNotificationTap?.call(details.notificationResponse!.payload);
  }

  Future<void> showPushMessage(PushMessage message) async {
    if (kIsWeb) {
      return;
    }
    if (!_initialized) {
      final bool ready = await ensureInitialized();
      if (!ready) {
        if (kDebugMode) {
          debugPrint('[LocalPushNotifications] show skipped: not initialized');
        }
        return;
      }
    }
    final String title = message.title ?? _channelName;
    final String body = (message.body != null && message.body!.isNotEmpty)
        ? message.body!
        : 'New message';
    final int? badgeCount = parsePushBadgeCount(message.payload);
    final Map<String, String> enrichedPayload = enrichPushPayload(
      message.payload,
    );
    final Map<String, String> payloadWithMessageId = Map<String, String>.from(
      enrichedPayload,
    );
    payloadWithMessageId[kLocalNotificationMessageIdKey] = message.id;

    if (defaultTargetPlatform == TargetPlatform.android) {
      final String? conversationKey = resolvePushGroupTag(enrichedPayload);
      final Uint8List? avatarBytes = await _fetchAvatarBytes(
        enrichedPayload['author_avatar_url'],
      );
      if (conversationKey != null) {
        await _showOrUpdateConversationNotification(
          conversationKey: conversationKey,
          title: title,
          body: body,
          payload: payloadWithMessageId,
          badgeCount: badgeCount,
          largeIcon: avatarBytes,
        );
        return;
      }
      final int id = pushMessageNotificationId(message.id);
      final NotificationDetails details = _notificationDetailsForPlatform(
        badgeCount: badgeCount,
        payload: enrichedPayload,
        largeIcon: avatarBytes,
      );
      try {
        await _plugin.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: details,
          payload: jsonEncode(payloadWithMessageId),
        );
      } on Object catch (e, st) {
        if (kDebugMode) {
          debugPrint('[LocalPushNotifications] show failed: $e\n$st');
        }
      }
      return;
    }

    final int id = pushMessageNotificationId(message.id);
    final NotificationDetails details = _notificationDetailsForPlatform(
      badgeCount: badgeCount,
      payload: enrichedPayload,
    );
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
        payload: jsonEncode(payloadWithMessageId),
      );
    } on Object catch (e, st) {
      if (kDebugMode) {
        debugPrint('[LocalPushNotifications] show failed: $e\n$st');
      }
    }
  }

  /// One notification per conversation, updated in place as messages arrive
  /// (Telegram/WhatsApp-style) instead of one notification per message.
  /// Collapsed shows the latest message; expanded (InboxStyle) shows the
  /// last few. All conversations share [_appGroupKey] so Android bundles
  /// them under one master notification (see [_updateAppSummary]).
  Future<void> _showOrUpdateConversationNotification({
    required String conversationKey,
    required String title,
    required String body,
    required Map<String, String> payload,
    int? badgeCount,
    Uint8List? largeIcon,
  }) async {
    final _ConversationState state = _conversationState.putIfAbsent(
      conversationKey,
      _ConversationState.new,
    );
    state.lines.add('$title: $body');
    if (state.lines.length > _maxGroupSummaryLines) {
      state.lines.removeRange(0, state.lines.length - _maxGroupSummaryLines);
    }
    state.totalCount++;
    final int conversationId = pushMessageNotificationId(
      'conversation:$conversationKey',
    );
    final String summaryText = state.totalCount == 1
        ? '1 new message'
        : '${state.totalCount} new messages';
    try {
      await _plugin.show(
        id: conversationId,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
            icon: _androidNotificationIcon,
            largeIcon: largeIcon != null
                ? ByteArrayAndroidBitmap(largeIcon)
                : null,
            number: badgeCount,
            groupKey: _appGroupKey,
            tag: conversationKey,
            groupAlertBehavior: GroupAlertBehavior.summary,
            styleInformation: InboxStyleInformation(
              state.lines,
              contentTitle: title,
              summaryText: summaryText,
            ),
          ),
        ),
        payload: jsonEncode(payload),
      );
    } on Object catch (e, st) {
      if (kDebugMode) {
        debugPrint(
          '[LocalPushNotifications] conversation show failed: $e\n$st',
        );
      }
    }
    await _updateAppSummary();
  }

  Future<void> _updateAppSummary() async {
    if (_conversationState.isEmpty) {
      try {
        await _plugin.cancel(id: _appSummaryNotificationId);
      } on Object catch (e, st) {
        if (kDebugMode) {
          debugPrint(
            '[LocalPushNotifications] app summary cancel failed: $e\n$st',
          );
        }
      }
      return;
    }
    final int chatCount = _conversationState.length;
    final int totalMessages = _conversationState.values.fold(
      0,
      (int sum, _ConversationState s) => sum + s.totalCount,
    );
    final String summaryText = chatCount == 1
        ? (totalMessages == 1 ? '1 new message' : '$totalMessages new messages')
        : '$totalMessages new messages across $chatCount chats';
    try {
      await _plugin.show(
        id: _appSummaryNotificationId,
        title: _channelName,
        body: summaryText,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
            icon: _androidNotificationIcon,
            groupKey: _appGroupKey,
            setAsGroupSummary: true,
            groupAlertBehavior: GroupAlertBehavior.summary,
          ),
        ),
      );
    } on Object catch (e, st) {
      if (kDebugMode) {
        debugPrint(
          '[LocalPushNotifications] app summary show failed: $e\n$st',
        );
      }
    }
  }

  Future<void> cancelForChannel(String channelId) async {
    if (kIsWeb || !_initialized || channelId.isEmpty) {
      return;
    }
    final String channelTag = buildChannelTag(channelId);
    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      try {
        await android.cancel(tag: channelTag, id: 0);
      } on Object catch (e, st) {
        if (kDebugMode) {
          debugPrint(
            '[LocalPushNotifications] cancel channel tag failed: $e\n$st',
          );
        }
      }
    }
    for (final int id in pushNotificationCancelIds(<String, String>{
      'channel_id': channelId,
      'tag': channelTag,
    })) {
      try {
        await _plugin.cancel(id: id, tag: channelTag);
      } on Object catch (e, st) {
        if (kDebugMode) {
          debugPrint(
            '[LocalPushNotifications] cancel channel id=$id failed: $e\n$st',
          );
        }
      }
    }
    _conversationState.remove(channelTag);
    try {
      await _plugin.cancel(
        id: pushMessageNotificationId('conversation:$channelTag'),
        tag: channelTag,
      );
    } on Object catch (e, st) {
      if (kDebugMode) {
        debugPrint(
          '[LocalPushNotifications] cancel conversation notification failed: $e\n$st',
        );
      }
    }
    await _updateAppSummary();
  }

  Future<void> cancelAll() async {
    if (kIsWeb || !_initialized) {
      return;
    }
    _conversationState.clear();
    try {
      await _plugin.cancelAll();
    } on Object catch (e, st) {
      if (kDebugMode) {
        debugPrint('[LocalPushNotifications] cancelAll failed: $e\n$st');
      }
    }
  }

  Future<void> cancelForPayload(Map<String, String> payload) async {
    if (kIsWeb || !_initialized) {
      return;
    }
    final String? messageTag = resolvePushMessageTag(payload);
    for (final int id in pushNotificationCancelIds(payload)) {
      try {
        await _plugin.cancel(id: id, tag: messageTag);
      } on Object catch (e, st) {
        if (kDebugMode) {
          debugPrint('[LocalPushNotifications] cancel failed id=$id: $e\n$st');
        }
      }
    }
  }

  NotificationDetails _notificationDetailsForPlatform({
    int? badgeCount,
    Map<String, String> payload = const <String, String>{},
    Uint8List? largeIcon,
  }) {
    final String? groupKey = resolvePushGroupTag(payload);
    final String? messageTag = resolvePushDisplayTag(payload);
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
            icon: _androidNotificationIcon,
            largeIcon: largeIcon != null
                ? ByteArrayAndroidBitmap(largeIcon)
                : null,
            number: badgeCount,
            groupKey: groupKey,
            tag: messageTag,
            // Only the group summary should alert (sound/vibrate/heads-up)
            // when there's a group to summarize — otherwise every message in
            // a burst alerts individually, which feels ungathered even
            // though they're already visually bundled by groupKey.
            groupAlertBehavior: groupKey != null
                ? GroupAlertBehavior.summary
                : GroupAlertBehavior.all,
          ),
        );
      case TargetPlatform.iOS:
        return const NotificationDetails(iOS: DarwinNotificationDetails());
      case TargetPlatform.macOS:
        return const NotificationDetails(macOS: DarwinNotificationDetails());
      case TargetPlatform.linux:
        return const NotificationDetails(
          linux: LinuxNotificationDetails(
            urgency: LinuxNotificationUrgency.normal,
          ),
        );
      case TargetPlatform.windows:
        return const NotificationDetails(windows: WindowsNotificationDetails());
      case TargetPlatform.fuchsia:
        return const NotificationDetails();
    }
  }
}

class _ConversationState {
  final List<String> lines = <String>[];
  int totalCount = 0;
}
