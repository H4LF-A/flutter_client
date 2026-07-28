import 'package:fluxer_app/core/push/push_message.dart';
import 'package:fluxer_dart/export.dart';
import 'package:fluxer_dart/gateway.dart';

/// Maps a raw [MessageResponseSchema] (from a live MessageCreateEvent, or a
/// bulk-fetched unread message on reconnect) straight to a [PushMessage],
/// skipping the DB-backed GatewayEventHandler used by the foreground app.
/// Returns null for the current user's own messages — the only filtering v1
/// does; per-channel mute state lives in the local database, which this
/// lightweight isolate deliberately doesn't touch for the live-message path
/// (the reconnect unread-sync path does apply mute filtering — see
/// background_gateway_unread_computation.dart).
PushMessage? mapMessageResponseToPushMessage(
  MessageResponseSchema message, {
  required String currentUserId,
}) {
  if (message.author.id == currentUserId) {
    return null;
  }
  final String title = message.author.globalName ?? message.author.username;
  final String body = message.content.isNotEmpty ? message.content : 'New message';
  return PushMessage(
    id: message.id,
    title: title,
    body: body,
    payload: <String, String>{
      'channel_id': message.channelId,
      'url': '/channels/@me/${message.channelId}',
    },
  );
}

/// Thin wrapper over [mapMessageResponseToPushMessage] for the live
/// MessageCreateEvent path.
PushMessage? mapMessageCreateEventToPushMessage(
  MessageCreateEvent event, {
  required String currentUserId,
}) {
  return mapMessageResponseToPushMessage(
    event.message,
    currentUserId: currentUserId,
  );
}
