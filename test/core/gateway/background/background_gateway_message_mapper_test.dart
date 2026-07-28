import 'package:flutter_test/flutter_test.dart';
import 'package:fluxer_app/core/gateway/background/background_gateway_message_mapper.dart';
import 'package:fluxer_dart/export.dart';
import 'package:fluxer_dart/gateway.dart';

MessageCreateEvent buildEvent({
  required String authorId,
  String messageId = '500',
  String channelId = '200',
  String content = 'hello',
  String? globalName,
}) {
  return MessageCreateEvent(
    message: MessageResponseSchema(
      id: messageId,
      channelId: channelId,
      author: UserPartialResponse(
        id: authorId,
        username: 'author',
        discriminator: '0001',
        globalName: globalName,
        avatar: null,
        avatarColor: null,
        flags: 0,
      ),
      type: MessageResponseSchemaTypeType.valueDefault,
      flags: 0,
      content: content,
      timestamp: DateTime.utc(2026),
      pinned: false,
      mentionEveryone: false,
      tts: false,
      mentions: const [],
      mentionRoles: const [],
    ),
  );
}

void main() {
  group('mapMessageCreateEventToPushMessage', () {
    test("returns null for the current user's own message", () {
      final event = buildEvent(authorId: '100');
      final message = mapMessageCreateEventToPushMessage(
        event,
        currentUserId: '100',
      );
      expect(message, isNull);
    });

    test("maps title, body, and payload for another user's message", () {
      final event = buildEvent(
        authorId: '200',
        globalName: 'Alice',
        content: 'hey there',
      );
      final message = mapMessageCreateEventToPushMessage(
        event,
        currentUserId: '100',
      );
      expect(message, isNotNull);
      expect(message!.id, '500');
      expect(message.title, 'Alice');
      expect(message.body, 'hey there');
      expect(message.payload['channel_id'], '200');
      expect(message.payload['url'], '/channels/@me/200');
    });

    test('falls back to username when globalName is null', () {
      final event = buildEvent(authorId: '200');
      final message = mapMessageCreateEventToPushMessage(
        event,
        currentUserId: '100',
      );
      expect(message!.title, 'author');
    });

    test('falls back to a generic body for empty content', () {
      final event = buildEvent(authorId: '200', content: '');
      final message = mapMessageCreateEventToPushMessage(
        event,
        currentUserId: '100',
      );
      expect(message!.body, 'New message');
    });
  });
}
