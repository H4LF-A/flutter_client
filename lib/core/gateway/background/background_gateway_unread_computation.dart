import 'package:fluxer_app/core/database/fluxer_database.dart' as db;
import 'package:fluxer_app/features/channels/data/read_state_utils.dart';
import 'package:fluxer_app/features/channels/data/unread_settings_resolver.dart';
import 'package:fluxer_app/features/channels/domain/channel.dart'
    show isGuildCategoryChannelType, isGuildVoiceChannelType;
import 'package:fluxer_dart/export.dart';
import 'package:fluxer_dart/gateway.dart';

/// A channel with unread messages, as computed straight from a ReadyEvent —
/// no local database involved.
class BackgroundUnreadChannel {
  const BackgroundUnreadChannel({
    required this.channelId,
    required this.guildId,
    required this.isDm,
    required this.ackLastMessageId,
  });

  final String channelId;
  final String? guildId;
  final bool isDm;
  final String? ackLastMessageId;
}

/// Pure, DB-free computation mirroring UnreadInboxCalculator's guild/DM
/// unread rules (mention count, mute state, category/voice filtering), using
/// only what the gateway's own ReadyEvent already carries as JSON. No
/// permission/channel-visibility filtering — that needs role/member/overwrite
/// data this lightweight isolate deliberately doesn't have; out of scope.
List<BackgroundUnreadChannel> computeUnreadChannelsFromReady(
  ReadyEvent event, {
  required String currentUserId,
  DateTime? now,
}) {
  final DateTime evaluatedAt = now ?? DateTime.now();
  final Map<String, GatewayReadState> readStateByChannelId = {
    for (final GatewayReadState r in event.readStates) r.id: r,
  };
  // Mirrors gateway_event_handler.dart's own normalization: DM-scope
  // settings arrive with guildId == null on the wire and are keyed as '@me'.
  final Map<String, UserGuildSettingsResponse> guildSettingsByScope = {
    for (final UserGuildSettingsResponse s in event.userGuildSettings ?? [])
      s.guildId ?? '@me': s,
  };

  final List<BackgroundUnreadChannel> result = [];

  for (final Map<String, dynamic> rawGuild in event.rawGuilds) {
    final bool unavailable = rawGuild['unavailable'] as bool? ?? false;
    if (unavailable) {
      continue;
    }
    final GuildCreateData guildData = GuildCreateData.fromJson(rawGuild);
    final String guildId = guildData.guild.id;
    final UserGuildSettingsResponse? guildSettings =
        guildSettingsByScope[guildId];
    for (final ChannelResponse channel in guildData.channels) {
      if (isGuildCategoryChannelType(channel.type)) {
        continue;
      }
      final GatewayReadState? readState = readStateByChannelId[channel.id];
      final int mentionCount = readState?.mentionCount ?? 0;
      if (isGuildVoiceChannelType(channel.type) && mentionCount == 0) {
        continue;
      }
      final db.Channel fakeChannel = db.Channel(
        id: channel.id,
        guildId: guildId,
        name: channel.name ?? '',
        type: channel.type,
        parentId: channel.parentId,
        position: channel.position ?? 0,
        rateLimitPerUser: channel.rateLimitPerUser ?? 0,
        nsfw: channel.nsfw ?? false,
        contentWarningLevel: channel.contentWarningLevel?.json ?? 0,
      );
      final ResolvedUnreadSettings settings = resolveChannelUnreadSettings(
        channel: fakeChannel,
        guildSettings: guildSettings,
        now: evaluatedAt,
      );
      if (settings.isMuted) {
        continue;
      }
      final bool hasUnread =
          mentionCount > 0 ||
          (settings.allowsMessageUnread &&
              hasUnreadByReadState(
                channelLastMessageId: channel.lastMessageId,
                ackLastMessageId: readState?.lastMessageId,
                fallbackAckMs: 0,
                mentionCount: 0,
                isGuildChannel: true,
              ));
      if (hasUnread) {
        result.add(
          BackgroundUnreadChannel(
            channelId: channel.id,
            guildId: guildId,
            isDm: false,
            ackLastMessageId: readState?.lastMessageId,
          ),
        );
      }
    }
  }

  final UserGuildSettingsResponse? dmSettings = guildSettingsByScope['@me'];
  for (final ChannelResponse channel in event.privateChannels) {
    if (allowNoMessagesForPrivateChannel(
      guildSettings: dmSettings,
      channelId: channel.id,
      now: evaluatedAt,
    )) {
      continue;
    }
    final GatewayReadState? readState = readStateByChannelId[channel.id];
    final bool hasUnread = hasUnreadByReadState(
      channelLastMessageId: channel.lastMessageId,
      ackLastMessageId: readState?.lastMessageId,
      fallbackAckMs: snowflakeTimestampMs(channel.id),
      mentionCount: readState?.mentionCount ?? 0,
    );
    if (hasUnread) {
      result.add(
        BackgroundUnreadChannel(
          channelId: channel.id,
          guildId: null,
          isDm: true,
          ackLastMessageId: readState?.lastMessageId,
        ),
      );
    }
  }

  return result;
}
