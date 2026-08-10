import 'dart:async';

import 'package:fluxer_app/core/providers/gateway_provider.dart';
import 'package:fluxer_app/core/talker.dart';
import 'package:fluxer_app/features/members/providers/guild_member_chunk_waiter.dart';
import 'package:fluxer_app/features/members/providers/guild_roles_provider.dart';
import 'package:fluxer_app/features/members/providers/member_providers.dart';
import 'package:fluxer_dart/gateway.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'guild_sync_provider.g.dart';

@Riverpod(keepAlive: true)
class GuildSync extends _$GuildSync {
  @override
  Set<String> build() => {};

  void syncIfNeeded(String guildId, {bool force = false}) {
    if (!force && state.contains(guildId)) {
      return;
    }

    final connection = ref.read(gatewayConnectionProvider);
    if (connection.state != GatewayState.connected) {
      return;
    }

    try {
      connection.sendLazyRequest(
        subscriptions: {
          guildId: const LazyRequestSubscription(active: true, sync: true),
        },
      );
      state = {...state, guildId};
      prefetchGuildRoles(ref.read(memberRepositoryProvider), guildId);
    } on Object catch (e) {
      talker.warning('[GuildSync] Failed to sync guild $guildId: $e');
    }
  }

  /// Marks every guild in [guildIds] active in one batched request, skipping
  /// ones already synced this session. The server only pushes incremental
  /// per-guild events (voice state joins/leaves, member updates) to sessions
  /// that have marked that guild active - without this, only the guild the
  /// user happens to have open receives live updates, leaving every other
  /// guild's sidebar voice indicators stuck at whatever snapshot was current
  /// when the session connected until the user taps into that guild.
  void syncAllIfNeeded(Iterable<String> guildIds) {
    final connection = ref.read(gatewayConnectionProvider);
    if (connection.state != GatewayState.connected) {
      return;
    }
    final List<String> pending = guildIds
        .where((String id) => !state.contains(id))
        .toList();
    if (pending.isEmpty) {
      return;
    }
    try {
      connection.sendLazyRequest(
        subscriptions: {
          for (final String guildId in pending)
            guildId: const LazyRequestSubscription(active: true, sync: true),
        },
      );
      state = {...state, ...pending};
      for (final String guildId in pending) {
        prefetchGuildRoles(ref.read(memberRepositoryProvider), guildId);
      }
    } on Object catch (e) {
      talker.warning('[GuildSync] Failed to sync all guilds: $e');
    }
  }

  Future<void> backfillMembersIfSparse(String guildId) async {
    await ref
        .read(guildMemberChunkWaiterProvider)
        .waitForChunk(guildId, timeout: const Duration(seconds: 3));
    try {
      await ref.read(memberRepositoryProvider).backfillMembersIfSparse(guildId);
    } on Object catch (e) {
      talker.warning(
        '[GuildSync] REST member backfill failed for $guildId: $e',
      );
    }
  }

  void clearAll() {
    if (state.isEmpty) {
      return;
    }
    state = {};
  }
}
