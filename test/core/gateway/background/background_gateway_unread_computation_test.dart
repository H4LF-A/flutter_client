import 'package:flutter_test/flutter_test.dart';
import 'package:fluxer_app/core/gateway/background/background_gateway_unread_computation.dart';
import 'package:fluxer_dart/export.dart';
import 'package:fluxer_dart/gateway.dart';

const int _kGuildText = 0;
const int _kGuildVoice = 2;
const int _kGuildCategory = 4;

Map<String, dynamic> _guildRaw({
  required String id,
  List<Map<String, Object?>> channels = const [],
  bool unavailable = false,
}) => {
  'id': id,
  'unavailable': unavailable,
  'properties': {
    'id': id,
    'name': 'Guild $id',
    'splash_card_alignment': 0,
    'owner_id': '100',
    'system_channel_flags': 0,
    'afk_timeout': 300,
    'features': <String>[],
    'verification_level': 0,
    'mfa_level': 0,
    'nsfw_level': 0,
    'nsfw': false,
    'content_warning_level': 0,
    'explicit_content_filter': 0,
    'default_message_notifications': 0,
    'disabled_operations': 0,
  },
  'channels': channels,
  'members': <Map<String, Object?>>[],
  'roles': <Map<String, Object?>>[],
  'presences': <Map<String, Object?>>[],
  'voice_states': <Map<String, Object?>>[],
  'emojis': <Map<String, Object?>>[],
  'stickers': <Map<String, Object?>>[],
};

Map<String, Object?> _channelRaw({
  required String id,
  int type = _kGuildText,
  String? lastMessageId,
  String? parentId,
}) => {
  'id': id,
  'type': type,
  'last_message_id': lastMessageId,
  'parent_id': parentId,
};

UserPrivateResponse _privateUser(String id) => UserPrivateResponse(
  hasVerifiedPhone: false,
  username: 'user-$id',
  discriminator: '0001',
  globalName: null,
  avatar: null,
  avatarColor: null,
  privacyAgreedAt: null,
  termsAgreedAt: null,
  pendingBulkMessageDeletion: null,
  flags: 0,
  unreadGiftInventoryCount: 0,
  isStaff: false,
  acls: const [],
  traits: const [],
  email: null,
  hasUnreadGiftInventory: false,
  hasEverPurchased: false,
  id: id,
  bio: null,
  pronouns: null,
  accentColor: null,
  banner: null,
  hasDismissedPremiumOnboarding: false,
  bannerColor: null,
  mfaEnabled: false,
  nsfwAllowed: true,
  verified: true,
  premiumType: null,
  premiumSince: null,
  premiumUntil: null,
  premiumWillCancel: false,
  premiumBillingCycle: null,
  premiumLifetimeSequence: null,
  premiumGraceEndsAt: null,
  premiumDiscriminator: false,
  requiredActions: const [],
  premiumBadgeMasked: false,
  premiumBadgeTimestampHidden: false,
  premiumBadgeSequenceHidden: false,
  premiumPurchaseDisabled: false,
  premiumEnabledOverride: false,
  passwordLastChangedAt: null,
  lastVoiceActivitySharingChangeAt: null,
  premiumBadgeHidden: false,
  premiumPerksDisabled: false,
);

ReadyEvent _readyEvent({
  List<Map<String, dynamic>> rawGuilds = const [],
  List<ChannelResponse> privateChannels = const [],
  List<GatewayReadState> readStates = const [],
  List<UserGuildSettingsResponse>? userGuildSettings,
}) => ReadyEvent(
  sessionId: 'session-1',
  user: _privateUser('me'),
  guilds: const [],
  rawGuilds: rawGuilds,
  privateChannels: privateChannels,
  relationships: const [],
  readStates: readStates,
  presences: const [],
  userGuildSettings: userGuildSettings,
);

// Whole-guild `.muted` isn't actually checked by resolveChannelUnreadSettings
// (confirmed: unread_inbox_calculator.dart, which this mirrors, never reads
// it either) — only a per-channel override does, via isChannelDirectlyMuted.
UserGuildSettingsResponse _settingsWithMutedChannel({
  required String? guildId,
  required String mutedChannelId,
}) => UserGuildSettingsResponse(
  guildId: guildId,
  messageNotifications: UserNotificationSettings.allMessages,
  muted: false,
  muteConfig: null,
  mobilePush: true,
  suppressEveryone: false,
  suppressRoles: false,
  hideMutedChannels: false,
  channelOverrides: {
    mutedChannelId: const ChannelOverrides(
      collapsed: false,
      messageNotifications: UserNotificationSettings.inherit,
      muted: true,
      muteConfig: null,
    ),
  },
  version: 1,
);

UserGuildSettingsResponse _dmMutedSettings() => const UserGuildSettingsResponse(
  guildId: null,
  messageNotifications: UserNotificationSettings.noMessages,
  muted: false,
  muteConfig: null,
  mobilePush: true,
  suppressEveryone: false,
  suppressRoles: false,
  hideMutedChannels: false,
  channelOverrides: {},
  version: 1,
);

void main() {
  group('computeUnreadChannelsFromReady', () {
    test('includes a guild text channel with a stale ack', () {
      final event = _readyEvent(
        rawGuilds: [
          _guildRaw(
            id: 'g1',
            channels: [
              _channelRaw(id: 'c1', lastMessageId: '200'),
            ],
          ),
        ],
        readStates: const [GatewayReadState(id: 'c1', lastMessageId: '100')],
      );
      final result = computeUnreadChannelsFromReady(event, currentUserId: 'me');
      expect(result, hasLength(1));
      expect(result.single.channelId, 'c1');
      expect(result.single.isDm, isFalse);
      expect(result.single.guildId, 'g1');
    });

    test('excludes a muted guild channel even with a stale ack', () {
      final event = _readyEvent(
        rawGuilds: [
          _guildRaw(
            id: 'g1',
            channels: [
              _channelRaw(id: 'c1', lastMessageId: '200'),
            ],
          ),
        ],
        readStates: const [GatewayReadState(id: 'c1', lastMessageId: '100')],
        userGuildSettings: [
          _settingsWithMutedChannel(guildId: 'g1', mutedChannelId: 'c1'),
        ],
      );
      final result = computeUnreadChannelsFromReady(event, currentUserId: 'me');
      expect(result, isEmpty);
    });

    test('always excludes category channels', () {
      final event = _readyEvent(
        rawGuilds: [
          _guildRaw(
            id: 'g1',
            channels: [
              _channelRaw(
                id: 'c1',
                type: _kGuildCategory,
                lastMessageId: '200',
              ),
            ],
          ),
        ],
        readStates: const [GatewayReadState(id: 'c1', lastMessageId: '100')],
      );
      final result = computeUnreadChannelsFromReady(event, currentUserId: 'me');
      expect(result, isEmpty);
    });

    test('excludes a voice channel with no mentions, includes one with mentions', () {
      final noMentionEvent = _readyEvent(
        rawGuilds: [
          _guildRaw(
            id: 'g1',
            channels: [
              _channelRaw(id: 'c1', type: _kGuildVoice, lastMessageId: '200'),
            ],
          ),
        ],
        readStates: const [GatewayReadState(id: 'c1', lastMessageId: '100')],
      );
      expect(
        computeUnreadChannelsFromReady(noMentionEvent, currentUserId: 'me'),
        isEmpty,
      );

      final mentionEvent = _readyEvent(
        rawGuilds: [
          _guildRaw(
            id: 'g1',
            channels: [
              _channelRaw(id: 'c1', type: _kGuildVoice, lastMessageId: '200'),
            ],
          ),
        ],
        readStates: const [
          GatewayReadState(id: 'c1', lastMessageId: '100', mentionCount: 1),
        ],
      );
      expect(
        computeUnreadChannelsFromReady(mentionEvent, currentUserId: 'me'),
        hasLength(1),
      );
    });

    test('includes a never-acked DM with a recent last message', () {
      // Real snowflakes: the channel "created at" timestamp is embedded in
      // its own id, so a last-message id with a numerically much larger
      // value decodes to a later timestamp — recent relative to the channel.
      final event = _readyEvent(
        privateChannels: const [
          ChannelResponse(
            id: '100000000000000000',
            type: 1,
            lastMessageId: '900000000000000000',
          ),
        ],
      );
      final result = computeUnreadChannelsFromReady(event, currentUserId: 'me');
      expect(result, hasLength(1));
      expect(result.single.isDm, isTrue);
      expect(result.single.guildId, isNull);
    });

    test('excludes DMs muted via @me settings (guildId null on the wire)', () {
      final event = _readyEvent(
        privateChannels: const [
          ChannelResponse(
            id: '100000000000000000',
            type: 1,
            lastMessageId: '900000000000000000',
          ),
        ],
        userGuildSettings: [_dmMutedSettings()],
      );
      final result = computeUnreadChannelsFromReady(event, currentUserId: 'me');
      expect(result, isEmpty);
    });

    test('never surfaces channels from an unavailable guild', () {
      final event = _readyEvent(
        rawGuilds: [
          _guildRaw(
            id: 'g1',
            unavailable: true,
            channels: [
              _channelRaw(id: 'c1', lastMessageId: '200'),
            ],
          ),
        ],
        readStates: const [GatewayReadState(id: 'c1', lastMessageId: '100')],
      );
      final result = computeUnreadChannelsFromReady(event, currentUserId: 'me');
      expect(result, isEmpty);
    });
  });
}
