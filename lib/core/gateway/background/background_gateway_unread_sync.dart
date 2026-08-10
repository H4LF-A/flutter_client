import 'package:dio/dio.dart';
import 'package:fluxer_app/core/gateway/background/background_gateway_message_mapper.dart';
import 'package:fluxer_app/core/gateway/background/background_gateway_unread_computation.dart';
import 'package:fluxer_app/core/push/local_push_notifications.dart';
import 'package:fluxer_dart/export.dart';
import 'package:fluxer_dart/gateway.dart';

const int _kUnreadSyncPerChannelLimit = 10;

/// On a fresh gateway ReadyEvent (a true reconnect/re-identify, not a
/// resume), computes everything currently unread and fetches+shows a
/// notification for each message — the "show me everything I missed"
/// counterpart to the live per-message MessageCreateEvent path. A failed
/// pass isn't fatal: the live path keeps working regardless, and the next
/// reconnect retries.
Future<void> runBackgroundGatewayUnreadSync({
  required ReadyEvent event,
  required String currentUserId,
  required String apiBaseUrl,
  String? mediaBaseUrl,
  required String token,
  required bool isAppForeground,
}) async {
  try {
    final List<BackgroundUnreadChannel> unread = computeUnreadChannelsFromReady(
      event,
      currentUserId: currentUserId,
    );
    if (unread.isEmpty || isAppForeground) {
      return;
    }
    final Dio dio = Dio(
      BaseOptions(baseUrl: apiBaseUrl, headers: {'Authorization': token}),
    );
    final ChannelsApi channelsApi = ChannelsApi(dio);
    final BulkMessageFetchResponse response = await channelsApi
        .bulkListChannelMessages(
          body: BulkMessageFetchRequest(
            requests: [
              for (final BackgroundUnreadChannel channel in unread)
                BulkMessageFetchRequestRequests(
                  channelId: channel.channelId,
                  limit: _kUnreadSyncPerChannelLimit,
                  after: channel.ackLastMessageId,
                ),
            ],
          ),
        );
    for (final channel in response.channels) {
      for (final message in channel.messages) {
        final pushMessage = mapMessageResponseToPushMessage(
          message,
          currentUserId: currentUserId,
          mediaBaseUrl: mediaBaseUrl,
        );
        if (pushMessage != null) {
          await LocalPushNotifications().showPushMessage(pushMessage);
        }
      }
    }
  } on Object {
    // Swallow: a failed sync pass just means we retry on the next reconnect;
    // the live MessageCreateEvent path is unaffected.
  }
}
