import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxer_app/core/theme/fluxer_theme_extension.dart';
import 'package:fluxer_app/features/ui/avatar/fluxer_avatar.dart';
import 'package:fluxer_app/features/ui/voice/fluxer_live_badge.dart';
import 'package:fluxer_app/features/voice/providers/voice_channel_participants_provider.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

class VoiceChannelParticipantsList extends ConsumerWidget {
  const VoiceChannelParticipantsList({
    required this.guildId,
    required this.channelId,
    super.key,
  });

  final String guildId;
  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String key = voiceChannelParticipantsFamilyKey(guildId, channelId);
    final AsyncValue<List<VoiceSidebarParticipant>> async = ref.watch(
      voiceChannelSidebarParticipantsProvider(key),
    );
    return async.when(
      data: (List<VoiceSidebarParticipant> list) {
        if (list.isEmpty) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < list.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(height: 2),
                _VoiceChannelParticipantTile(participant: list[i]),
              ],
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

class _VoiceChannelParticipantTile extends StatelessWidget {
  const _VoiceChannelParticipantTile({required this.participant});

  final VoiceSidebarParticipant participant;

  @override
  Widget build(BuildContext context) {
    final VoiceSidebarParticipant p = participant;
    final bool showMic = p.guildMute || p.selfMute;
    final bool micDanger = p.guildMute;
    final bool showDeaf = p.guildDeaf || p.selfDeaf;
    final bool deafDanger = p.guildDeaf;
    final bool hasIcons = p.selfVideo || showMic || showDeaf || p.selfStream;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: <Widget>[
          FluxerAvatar.user(
            imageUrl: p.avatarUrl,
            fallbackText: p.displayName,
            size: 20,
            showStatus: false,
            avatarColor: p.avatarColor,
            userId: p.userId,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              p.displayName,
              style: context.textStyles.channelName.copyWith(
                color: context.colors.textTertiary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (hasIcons) ...<Widget>[
            const SizedBox(width: 4),
            _VoiceParticipantStatusIcons(
              selfVideo: p.selfVideo,
              showMic: showMic,
              micDanger: micDanger,
              showDeaf: showDeaf,
              deafDanger: deafDanger,
              selfStream: p.selfStream,
            ),
          ],
        ],
      ),
    );
  }
}

class _VoiceParticipantStatusIcons extends StatelessWidget {
  const _VoiceParticipantStatusIcons({
    required this.selfVideo,
    required this.showMic,
    required this.micDanger,
    required this.showDeaf,
    required this.deafDanger,
    required this.selfStream,
  });

  final bool selfVideo;
  final bool showMic;
  final bool micDanger;
  final bool showDeaf;
  final bool deafDanger;
  final bool selfStream;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (selfVideo)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: PhosphorIcon(
              PhosphorIconsFill.videoCamera,
              size: 14,
              color: context.colors.textSecondary,
            ),
          ),
        if (showMic)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: PhosphorIcon(
              PhosphorIconsFill.microphoneSlash,
              size: 14,
              color: micDanger
                  ? context.colors.statusDanger
                  : context.colors.textSecondary,
            ),
          ),
        if (showDeaf)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: PhosphorIcon(
              PhosphorIconsFill.speakerSlash,
              size: 14,
              color: deafDanger
                  ? context.colors.statusDanger
                  : context.colors.textSecondary,
            ),
          ),
        if (selfStream) const FluxerLiveBadge(),
      ],
    );
  }
}
