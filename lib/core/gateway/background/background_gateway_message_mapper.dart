import 'package:fluxer_app/core/media/fluxer_media_hash.dart';
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
  String? mediaBaseUrl,
}) {
  if (message.author.id == currentUserId) {
    return null;
  }
  final String title = message.author.globalName ?? message.author.username;
  final String body = message.content.isNotEmpty ? message.content : 'New message';
  final Map<String, String> payload = <String, String>{
    'channel_id': message.channelId,
    'url': '/channels/@me/${message.channelId}',
  };
  final String? avatarUrl = _buildAuthorAvatarUrl(
    mediaBaseUrl: mediaBaseUrl,
    userId: message.author.id,
    avatarHash: message.author.avatar,
  );
  if (avatarUrl != null) {
    payload['author_avatar_url'] = avatarUrl;
  }
  return PushMessage(id: message.id, title: title, body: body, payload: payload);
}

/// Thin wrapper over [mapMessageResponseToPushMessage] for the live
/// MessageCreateEvent path.
PushMessage? mapMessageCreateEventToPushMessage(
  MessageCreateEvent event, {
  required String currentUserId,
  String? mediaBaseUrl,
}) {
  return mapMessageResponseToPushMessage(
    event.message,
    currentUserId: currentUserId,
    mediaBaseUrl: mediaBaseUrl,
  );
}

// Deliberately not FluxerMediaUrl.userAvatar: that reads InstanceEndpoints.media,
// a global populated by fetching /.well-known/fluxer in the main isolate -
// static state that doesn't cross into this headless background isolate.
// [mediaBaseUrl] comes from BackgroundGatewaySessionSnapshot instead.
String? _buildAuthorAvatarUrl({
  required String? mediaBaseUrl,
  required String userId,
  required String? avatarHash,
}) {
  if (mediaBaseUrl == null ||
      mediaBaseUrl.isEmpty ||
      avatarHash == null ||
      avatarHash.isEmpty) {
    return null;
  }
  final String normalizedHash = normalizeMediaHash(avatarHash);
  return '$mediaBaseUrl/avatars/$userId/$normalizedHash.webp?size=128';
}
