import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:fluxer_app/core/talker.dart';
import 'package:fluxer_app/features/voice/domain/voice_settings_state.dart';
import 'package:fluxer_app/features/voice/providers/voice_noise_filter_provider.dart';
import 'package:fluxer_app/features/voice/utils/camera_resolution_presets.dart';
import 'package:fluxer_app/features/voice/utils/screen_share_presets.dart';
import 'package:fluxer_app/features/voice/utils/voice_camera_platform.dart';
import 'package:fluxer_app/features/voice/utils/voice_processing_profile.dart';
import 'package:fluxer_app/features/voice/utils/voice_volume_utils.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_noise_filter/livekit_noise_filter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'voice_settings_applicator.g.dart';

class VoiceSettingsApplicator {
  const VoiceSettingsApplicator({
    required this.noiseFilter,
    required this.noiseFilterSupported,
  });

  final LiveKitNoiseFilter? noiseFilter;
  final bool noiseFilterSupported;

  RoomOptions buildRoomOptions(VoiceSettingsState settings) {
    final ResolvedVoiceProcessing processing = resolveVoiceProcessing(
      settings: settings,
      noiseFilterSupported: noiseFilterSupported,
    );
    final String? audioDeviceId = _resolveDeviceId(settings.inputDeviceId);
    return RoomOptions(
      adaptiveStream: true,
      dynacast: true,
      defaultAudioCaptureOptions: AudioCaptureOptions(
        deviceId: audioDeviceId,
        echoCancellation: processing.echoCancellation,
        noiseSuppression: processing.noiseSuppression,
        autoGainControl: processing.autoGainControl,
        processor: noiseFilterSupported ? noiseFilter : null,
      ),
      // Opus DTX defaults to enabled in this SDK. Its silence-detection
      // re-engage causes an audible muffled/choppy artifact right after a
      // period of low signal - exactly what noise suppression produces at
      // the moment it starts attenuating background noise, since DTX's
      // heuristic reads that transition as "was silent, now speaking again"
      // even mid-sentence. fluxer_desktop's native voice engine had this
      // identical bug (hardcoded dtx: true) and fixed it by disabling DTX
      // for mic tracks; the browser client works around it at the SDP fmtp
      // layer (usedtx=0). This SDK exposes the same switch directly.
      defaultAudioPublishOptions: const AudioPublishOptions(dtx: false),
      defaultCameraCaptureOptions: cameraCaptureOptionsFor(
        resolution: settings.cameraResolution,
        deviceId: settings.videoDeviceId,
        cameraFacing: settings.cameraFacing,
      ),
      defaultScreenShareCaptureOptions: screenShareCaptureOptionsFor(
        resolution: settings.screenshareResolution,
        frameRate: settings.videoFrameRate,
      ),
    );
  }

  AudioCaptureOptions buildAudioCaptureOptions(VoiceSettingsState settings) {
    final ResolvedVoiceProcessing processing = resolveVoiceProcessing(
      settings: settings,
      noiseFilterSupported: noiseFilterSupported,
    );
    return AudioCaptureOptions(
      deviceId: _resolveDeviceId(settings.inputDeviceId),
      echoCancellation: processing.echoCancellation,
      noiseSuppression: processing.noiseSuppression,
      autoGainControl: processing.autoGainControl,
      processor: noiseFilterSupported ? noiseFilter : null,
    );
  }

  CameraCaptureOptions buildCameraCaptureOptions(VoiceSettingsState settings) {
    return cameraCaptureOptionsFor(
      resolution: settings.cameraResolution,
      deviceId: settings.videoDeviceId,
      cameraFacing: settings.cameraFacing,
    );
  }

  ScreenShareCaptureOptions buildScreenShareCaptureOptions(
    VoiceSettingsState settings,
  ) {
    return screenShareCaptureOptionsFor(
      resolution: settings.screenshareResolution,
      frameRate: settings.videoFrameRate,
    );
  }

  Future<void> applyNoiseFilterBypass(VoiceSettingsState settings) async {
    final ResolvedVoiceProcessing processing = resolveVoiceProcessing(
      settings: settings,
      noiseFilterSupported: noiseFilterSupported,
    );
    // Krisp requires authenticating against LiveKit Cloud for license
    // validation, which a self-hosted server can't provide - it silently
    // passes audio through unprocessed on Android instead of erroring.
    // "Enhanced" on Android is driven by a native DeepFilterNet port instead
    // (same model desktop/web use, see DeepFilterNoiseProcessor.kt), so
    // Krisp itself stays permanently bypassed there.
    if (!kIsWeb && Platform.isAndroid) {
      await AudioManager.instance.setAndroidEnhancedNoiseSuppressionEnabled(
        processing.useNoiseFilter,
      );
      if (noiseFilterSupported && noiseFilter != null) {
        await noiseFilter!.setBypass(true);
      }
      return;
    }
    if (!noiseFilterSupported || noiseFilter == null) {
      return;
    }
    await noiseFilter!.setBypass(processing.bypassNoiseFilter);
  }

  Future<void> refreshMicrophone({
    required Room room,
    required VoiceSettingsState settings,
    required bool microphoneEnabled,
  }) async {
    final LocalParticipant? participant = room.localParticipant;
    if (participant == null) {
      return;
    }
    await applyNoiseFilterBypass(settings);
    if (!microphoneEnabled) {
      return;
    }
    await participant.setMicrophoneEnabled(
      false,
      audioCaptureOptions: buildAudioCaptureOptions(settings),
    );
    await participant.setMicrophoneEnabled(
      true,
      audioCaptureOptions: buildAudioCaptureOptions(settings),
    );
    // The audio session policy (MODE_NORMAL etc.) is only ever applied once,
    // at Room.connect() time (see NativeAudioManagement.start(), called from
    // room.dart before engine.connect()) - it's never re-applied on a later
    // mic republish like the one above. Recreating the LocalAudioTrack here
    // lets the platform ADM's own low-level setup run unopposed for that new
    // track, the same way the standalone mic test used to before it started
    // calling this too - so any settings change that republishes the mic
    // (tier, device, EC) can silently revert Android to MODE_IN_COMMUNICATION
    // mid-call. Re-assert the policy after republishing to close that gap.
    await AudioManager.instance.applyOptionsForConnect();
    await applyInputVolume(room: room, settings: settings);
  }

  /// Applies the input-volume gain to the currently published microphone
  /// track. Volume isn't part of AudioCaptureOptions/MediaConstraints - it's
  /// a runtime gain applied directly to the track - so it has to be
  /// re-applied here on every mic (re)publish, not just once at creation.
  Future<void> applyInputVolume({
    required Room room,
    required VoiceSettingsState settings,
  }) async {
    final LocalParticipant? participant = room.localParticipant;
    if (participant == null) {
      talker.info('[Voice] applyInputVolume: no local participant');
      return;
    }
    final LocalTrackPublication? publication = participant
        .getTrackPublicationBySource(TrackSource.microphone);
    final LocalAudioTrack? track = publication?.track is LocalAudioTrack
        ? publication!.track! as LocalAudioTrack
        : null;
    if (track == null) {
      talker.info(
        '[Voice] applyInputVolume: no local mic track '
        '(publication=${publication != null}, track=${publication?.track?.runtimeType})',
      );
      return;
    }
    final double gain = inputVoiceVolumePercentToGain(settings.inputVolume);
    talker.info(
      '[Voice] applyInputVolume: applying gain=$gain '
      'inputVolume=${settings.inputVolume} trackId=${track.mediaStreamTrack.id}',
    );
    // Helper.setVolume only affects remote/playout tracks on Android, not the
    // local capture track it's called on here - it's a harmless no-op on
    // Android and is kept for the platforms where it does apply. The actual
    // Android fix is a software gain in flutter_webrtc's capture-time audio
    // processing hook.
    await Helper.setVolume(
      gain,
      track.mediaStreamTrack,
    );
    await AudioManager.instance.setAndroidInputGain(gain);
  }

  Future<void> refreshCamera({
    required Room room,
    required VoiceSettingsState settings,
    required bool cameraEnabled,
  }) async {
    final LocalParticipant? participant = room.localParticipant;
    if (participant == null) {
      return;
    }
    final CameraCaptureOptions options = buildCameraCaptureOptions(settings);
    if (!cameraEnabled) {
      await participant.setCameraEnabled(false, cameraCaptureOptions: options);
      return;
    }
    final LocalTrackPublication? publication = participant
        .getTrackPublicationBySource(TrackSource.camera);
    final LocalVideoTrack? track = publication?.track is LocalVideoTrack
        ? publication!.track! as LocalVideoTrack
        : null;
    if (track != null) {
      if (isMobileVoiceCameraPlatform()) {
        await track.setCameraPosition(
          liveKitCameraPosition(settings.cameraFacing),
        );
        return;
      }
      await track.restartTrack(options);
      return;
    }
    await participant.setCameraEnabled(true, cameraCaptureOptions: options);
  }

  Future<void> applySpeakerOutput({
    required VoiceSettingsState settings,
  }) async {
    if (!AudioManager.instance.canSwitchSpeakerphone) {
      return;
    }
    await AudioManager.instance.setSpeakerOutputPreferred(
      settings.preferSpeakerOutput,
    );
  }

  /// Switches which Android stream type (STREAM_VOICE_CALL vs STREAM_MUSIC)
  /// the platform associates with this app's audio session - which is what
  /// physical volume buttons actually follow, independent of AudioManager's
  /// mode (already forced to 'normal' at startup, see main.dart) or
  /// anything about digital signal loudness. Re-applies the full session
  /// config (matching main.dart's startup config exactly, only the stream
  /// type varies) via setInitialAudioSessionOptions + applyOptionsForConnect
  /// so a mid-call settings toggle takes effect immediately rather than
  /// waiting for the next connect/republish.
  Future<void> applyAndroidAudioStreamType({
    required VoiceSettingsState settings,
  }) async {
    if (kIsWeb || !Platform.isAndroid) {
      return;
    }
    AudioManager.instance.setInitialAudioSessionOptions(
      AudioSessionOptions.communication(
        android: AndroidAudioSessionConfiguration(
          usageType: AndroidAudioAttributesUsageType.voiceCommunication,
          contentType: AndroidAudioAttributesContentType.speech,
          audioMode: AndroidAudioMode.normal,
          streamType: settings.androidUseMediaVolume
              ? AndroidAudioStreamType.music
              : AndroidAudioStreamType.voiceCall,
        ),
      ),
    );
    await AudioManager.instance.applyOptionsForConnect();
  }

  String? _resolveDeviceId(String deviceId) {
    if (deviceId == kDefaultVoiceDeviceId || deviceId.isEmpty) {
      return null;
    }
    return deviceId;
  }
}

@Riverpod(keepAlive: true)
VoiceSettingsApplicator voiceSettingsApplicator(Ref ref) {
  final AsyncValue<VoiceNoiseFilterState> noiseFilterState = ref.watch(
    voiceNoiseFilterProvider,
  );
  return noiseFilterState.maybeWhen(
    data: (VoiceNoiseFilterState value) => VoiceSettingsApplicator(
      noiseFilter: value.filter,
      noiseFilterSupported: value.isSupported,
    ),
    orElse: () => const VoiceSettingsApplicator(
      noiseFilter: null,
      noiseFilterSupported: false,
    ),
  );
}
