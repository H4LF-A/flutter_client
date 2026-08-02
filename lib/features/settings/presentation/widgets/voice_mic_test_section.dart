import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fluxer_app/core/system_permissions/system_permission_kind.dart';
import 'package:fluxer_app/core/system_permissions/system_permission_service.dart';
import 'package:fluxer_app/core/talker.dart';
import 'package:fluxer_app/core/theme/fluxer_theme_extension.dart';
import 'package:fluxer_app/features/settings/providers/voice_settings_provider.dart';
import 'package:fluxer_app/features/ui/button/fluxer_button.dart';
import 'package:fluxer_app/features/ui/ui.dart';
import 'package:fluxer_app/features/voice/domain/voice_settings_state.dart';
import 'package:fluxer_app/features/voice/providers/voice_session_provider.dart';
import 'package:fluxer_app/features/voice/providers/voice_session_state.dart';
import 'package:fluxer_app/features/voice/services/voice_settings_applicator.dart';
import 'package:fluxer_app/features/voice/utils/voice_processing_profile.dart';
import 'package:fluxer_app/features/voice/utils/voice_volume_utils.dart';
import 'package:fluxer_app/l10n/generated/fluxer_localizations.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_noise_filter/livekit_noise_filter.dart';

class VoiceMicTestSection extends ConsumerStatefulWidget {
  const VoiceMicTestSection({super.key});

  @override
  ConsumerState<VoiceMicTestSection> createState() =>
      _VoiceMicTestSectionState();
}

class _VoiceMicTestSectionState extends ConsumerState<VoiceMicTestSection> {
  LocalAudioTrack? _track;
  AudioVisualizer? _visualizer;
  EventsListener<AudioVisualizerEvent>? _visualizerListener;
  RTCVideoRenderer? _playbackRenderer;
  RTCPeerConnection? _loopbackLocalPeerConnection;
  RTCPeerConnection? _loopbackRemotePeerConnection;
  double _level = 0;
  bool _isRunning = false;
  // TEMPORARY diagnostic: surfaces LiveKit's live audio-processing state
  // (requested vs. resolved vs. actually-active, per component) directly in
  // this screen so it can be read off-device without a log-export flow.
  // Remove once the Android noise-suppression-tier investigation is done.
  AudioProcessingState? _processingState;
  // TEMPORARY diagnostic: shows the gain actually sent to Helper.setVolume
  // and re-applies it live while the test runs and the volume slider moves,
  // to isolate whether the underlying native volume mechanism has any
  // audible effect at all, independent of live-call complexity.
  double? _appliedGain;
  // TEMPORARY diagnostic: Krisp's own reported error code when "enhanced" is
  // active, see the authenticate() comment in _startTest.
  ErrorCode? _krispError;
  // TEMPORARY diagnostic: the sample rate/channel/band-framing WebRTC's
  // native capture audio processing hook actually uses on this device -
  // needed to scope a real DeepFilterNet noise-suppression port for Android.
  Map<String, dynamic>? _audioProcessingFormat;

  static const Map<String, dynamic> _loopbackConfiguration = <String, dynamic>{
    'iceServers': <Map<String, dynamic>>[],
    'sdpSemantics': 'unified-plan',
  };

  @override
  void dispose() {
    unawaited(_stopTest());
    super.dispose();
  }

  Future<void> _startTest() async {
    if (_isRunning) {
      return;
    }
    if (ref.read(voiceSessionProvider).isConnected) {
      return;
    }
    final bool micOk = await ensureSystemPermission(
      context,
      SystemPermissionKind.microphone,
    );
    if (!micOk || !mounted) {
      return;
    }
    final VoiceSettingsState settings = ref.read(voiceSettingsProvider);
    final VoiceSettingsApplicator applicator = ref.read(
      voiceSettingsApplicatorProvider,
    );
    final AudioCaptureOptions options = applicator.buildAudioCaptureOptions(
      settings,
    );
    final ResolvedVoiceProcessing processing = resolveVoiceProcessing(
      settings: settings,
      noiseFilterSupported: applicator.noiseFilterSupported,
    );
    ErrorCode? krispError;
    if (applicator.noiseFilter != null) {
      await applicator.noiseFilter!.setBypass(processing.bypassNoiseFilter);
      // TEMPORARY diagnostic: Krisp (the "enhanced" ML filter) requires
      // authenticating against LiveKit's own backend for license validation
      // (see LiveKitNoiseFilter.onPublish -> krisp.authenticate). Krisp noise
      // cancellation is normally a LiveKit Cloud feature - on a self-hosted
      // server that authentication likely fails, and the SDK probably just
      // passes audio through unprocessed as a fail-safe rather than erroring
      // loudly, which would look exactly like "enhanced does nothing".
      if (!processing.bypassNoiseFilter) {
        krispError = await applicator.noiseFilter!.lastError();
        talker.info('Mic test: Krisp lastError=$krispError');
      }
    }
    try {
      // The mic test deliberately runs outside a Room connection (see the
      // isConnected guard above), so the audio session never gets activated
      // via the normal room-connect path - without this, creating a raw
      // LocalAudioTrack lets the platform ADM's own low-level setup run
      // unopposed, which on Android can leave AudioManager in
      // MODE_IN_COMMUNICATION instead of this app's configured policy.
      await AudioManager.instance.applyOptionsForConnect();
      // Force speaker output for the test regardless of the user's regular
      // call preference (which defaults to earpiece/off): the whole point of
      // this test is to hear yourself while looking at the screen, not
      // holding the phone up like a call - on earpiece the playback is quiet
      // enough to seem like nothing is happening at all.
      if (AudioManager.instance.canSwitchSpeakerphone) {
        await AudioManager.instance.setSpeakerOutputPreferred(true);
      }
      await _configureOutputDevice(settings.outputDeviceId);
      final LocalAudioTrack track = await LocalAudioTrack.create(options);
      await track.start();
      final double gain = inputVoiceVolumePercentToGain(settings.inputVolume);
      await Helper.setVolume(gain, track.mediaStreamTrack);
      await AudioManager.instance.setAndroidInputGain(gain);
      talker.info('Mic test: applied initial gain=$gain');
      final AudioVisualizer visualizer = createVisualizer(
        track,
        options: const AudioVisualizerOptions(barCount: 8),
      );
      _visualizerListener = visualizer.createListener()
        ..on<AudioVisualizerEvent>((AudioVisualizerEvent event) {
          if (!mounted) {
            return;
          }
          setState(() {
            _level = _readVisualizerLevel(event);
          });
        });
      await visualizer.start();
      await _startPlayback(track, settings);
      final AudioProcessingState? processingState = await AudioManager
          .instance
          .getAudioProcessingState();
      talker.info('Mic test audio processing state', processingState);
      // TEMPORARY diagnostic: at least one frame has now gone through the
      // capture audio processing hook (the gain call above forces the
      // processor to be registered), so the format it observed is available.
      final Map<String, dynamic>? audioProcessingFormat = await AudioManager
          .instance
          .getAndroidAudioProcessingFormat();
      talker.info('Mic test audio processing format', audioProcessingFormat);
      if (!mounted) {
        await _disposePlayback();
        await _visualizerListener?.dispose();
        await visualizer.stop();
        await visualizer.dispose();
        await track.stop();
        return;
      }
      setState(() {
        _track = track;
        _visualizer = visualizer;
        _isRunning = true;
        _processingState = processingState;
        _appliedGain = gain;
        _krispError = krispError;
        _audioProcessingFormat = audioProcessingFormat;
      });
    } on Object catch (error, stackTrace) {
      talker.error('Failed to start mic test', error, stackTrace);
      await _stopTest();
      if (mounted) {
        setState(() {
          _isRunning = false;
        });
      }
    }
  }

  Future<void> _configureOutputDevice(String outputDeviceId) async {
    if (outputDeviceId == kDefaultVoiceDeviceId || outputDeviceId.isEmpty) {
      return;
    }
    // Helper.selectAudioOutput routes through flutter_webrtc's own
    // AudioSwitchManager, which this app disables in favor of LiveKit's own -
    // it's a silent no-op on Android, so use LiveKit's own selection there.
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await AudioManager.instance.selectAndroidOutputDevice(outputDeviceId);
      } on Object catch (error, stackTrace) {
        talker.warning('Failed to set mic test output device', error, stackTrace);
      }
      return;
    }
    if (kIsWeb || AudioManager.instance.canSwitchSpeakerphone) {
      return;
    }
    try {
      await Helper.selectAudioOutput(outputDeviceId);
    } on Object catch (error, stackTrace) {
      talker.warning('Failed to set mic test output device', error, stackTrace);
    }
  }

  Future<void> _startPlayback(
    LocalAudioTrack track,
    VoiceSettingsState settings,
  ) async {
    final RTCVideoRenderer renderer = RTCVideoRenderer();
    await renderer.initialize();
    final double outputVolume = boostedVoiceVolumePercentToTrackVolume(
      settings.outputVolume,
    );
    final String? outputDeviceId = _resolveOutputDeviceId(
      settings.outputDeviceId,
    );
    if (kIsWeb) {
      renderer.srcObject = track.mediaStream;
      if (outputDeviceId != null) {
        await renderer.audioOutput(outputDeviceId);
      }
      await renderer.setVolume(outputVolume);
      _playbackRenderer = renderer;
      return;
    }
    final RTCPeerConnection localPeerConnection = await createPeerConnection(
      _loopbackConfiguration,
    );
    final RTCPeerConnection remotePeerConnection = await createPeerConnection(
      _loopbackConfiguration,
    );
    remotePeerConnection.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'audio' && event.streams.isNotEmpty) {
        renderer.srcObject = event.streams.first;
      }
    };
    // Both sides must trickle their gathered ICE candidates to each other -
    // without this neither peer connection ever forms a usable candidate
    // pair, so no media flows even though signaling completes normally.
    localPeerConnection.onIceCandidate = (RTCIceCandidate candidate) {
      unawaited(remotePeerConnection.addCandidate(candidate));
    };
    remotePeerConnection.onIceCandidate = (RTCIceCandidate candidate) {
      unawaited(localPeerConnection.addCandidate(candidate));
    };
    await localPeerConnection.addTrack(
      track.mediaStreamTrack,
      track.mediaStream,
    );
    final RTCSessionDescription offer = await localPeerConnection.createOffer();
    await localPeerConnection.setLocalDescription(offer);
    await remotePeerConnection.setRemoteDescription(offer);
    final RTCSessionDescription answer = await remotePeerConnection
        .createAnswer();
    await remotePeerConnection.setLocalDescription(answer);
    await localPeerConnection.setRemoteDescription(answer);
    if (outputDeviceId != null) {
      await renderer.audioOutput(outputDeviceId);
    }
    await renderer.setVolume(outputVolume);
    _playbackRenderer = renderer;
    _loopbackLocalPeerConnection = localPeerConnection;
    _loopbackRemotePeerConnection = remotePeerConnection;
  }

  String? _resolveOutputDeviceId(String outputDeviceId) {
    if (outputDeviceId == kDefaultVoiceDeviceId || outputDeviceId.isEmpty) {
      return null;
    }
    return outputDeviceId;
  }

  double _readVisualizerLevel(AudioVisualizerEvent event) {
    double maxValue = 0;
    for (final Object? entry in event.event) {
      if (entry is num) {
        final double value = entry.toDouble();
        if (value > maxValue) {
          maxValue = value;
        }
      }
    }
    return maxValue.clamp(0, 1);
  }

  Future<void> _stopTest() async {
    await _visualizerListener?.dispose();
    _visualizerListener = null;
    await _visualizer?.stop();
    await _visualizer?.dispose();
    _visualizer = null;
    await _disposePlayback();
    await _track?.stop();
    _track = null;
    if (AudioManager.instance.canSwitchSpeakerphone) {
      final VoiceSettingsState settings = ref.read(voiceSettingsProvider);
      await AudioManager.instance.setSpeakerOutputPreferred(
        settings.preferSpeakerOutput,
      );
    }
    if (mounted) {
      setState(() {
        _isRunning = false;
        _level = 0;
        _processingState = null;
        _appliedGain = null;
        _krispError = null;
        _audioProcessingFormat = null;
      });
    }
  }

  // TEMPORARY diagnostic: reapplies gain live as the input-volume slider
  // moves while the test is running, isolating whether Helper.setVolume has
  // any audible effect at all, independent of live-call complexity.
  Future<void> _reapplyGainForRunningTest(int inputVolume) async {
    final LocalAudioTrack? track = _track;
    if (track == null) {
      return;
    }
    final double gain = inputVoiceVolumePercentToGain(inputVolume);
    talker.info('Mic test: reapplying gain=$gain (input volume changed)');
    await Helper.setVolume(gain, track.mediaStreamTrack);
    await AudioManager.instance.setAndroidInputGain(gain);
    if (mounted) {
      setState(() {
        _appliedGain = gain;
      });
    }
  }

  Future<void> _disposePlayback() async {
    await _loopbackLocalPeerConnection?.close();
    await _loopbackLocalPeerConnection?.dispose();
    _loopbackLocalPeerConnection = null;
    await _loopbackRemotePeerConnection?.close();
    await _loopbackRemotePeerConnection?.dispose();
    _loopbackRemotePeerConnection = null;
    if (_playbackRenderer != null) {
      _playbackRenderer!.srcObject = null;
      await _playbackRenderer!.dispose();
      _playbackRenderer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = FluxerLocalizations.of(context);
    final layout = context.layout;
    final colors = context.colors;
    final bool voiceCallActive = ref.watch(
      voiceSessionProvider.select(
        (VoiceSessionState state) => state.isConnected,
      ),
    );
    // TEMPORARY diagnostic: reapply gain live as the slider moves while the
    // test is running, instead of only once at test start.
    ref.listen<int>(
      voiceSettingsProvider.select((VoiceSettingsState s) => s.inputVolume),
      (int? previous, int next) {
        if (previous == next || !_isRunning) {
          return;
        }
        unawaited(_reapplyGainForRunningTest(next));
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 8,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _isRunning ? _level.clamp(0, 1) : 0,
              backgroundColor: colors.backgroundTertiary,
              color: colors.brandPrimary,
            ),
          ),
        ),
        SizedBox(height: layout.s3),
        FluxerButton.primary(
          label: _isRunning
              ? l10n.audioAndVideoMicTestStopLabel
              : l10n.audioAndVideoMicTestStartLabel,
          onPressed: voiceCallActive
              ? null
              : _isRunning
              ? () => unawaited(_stopTest())
              : () => unawaited(_startTest()),
        ),
        if (_appliedGain != null) ...[
          SizedBox(height: layout.s3),
          Text(
            'appliedGain=$_appliedGain',
            style: context.textStyles.bodySmall.copyWith(
              color: colors.textSecondary,
              fontFamily: 'monospace',
            ),
          ),
        ],
        if (_processingState != null) ...[
          SizedBox(height: layout.s3),
          Text(
            _formatProcessingState(_processingState!),
            style: context.textStyles.bodySmall.copyWith(
              color: colors.textSecondary,
              fontFamily: 'monospace',
            ),
          ),
        ],
        if (_krispError != null) ...[
          SizedBox(height: layout.s3),
          Text(
            'krispLastError=$_krispError',
            style: context.textStyles.bodySmall.copyWith(
              color: colors.textSecondary,
              fontFamily: 'monospace',
            ),
          ),
        ],
        if (_audioProcessingFormat != null) ...[
          SizedBox(height: layout.s3),
          Text(
            'audioProcessingFormat=$_audioProcessingFormat',
            style: context.textStyles.bodySmall.copyWith(
              color: colors.textSecondary,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ],
    );
  }

  // TEMPORARY diagnostic formatter, see _processingState above.
  String _formatProcessingState(AudioProcessingState state) {
    String component(String label, AudioProcessingComponentState c) {
      return '$label: effective=${c.effective.value} '
          'requested=${c.requested?.enabled}/${c.requested?.mode.constraintValue} '
          'sw(resolved=${c.isSoftwareResolved},active=${c.isSoftwareActive}) '
          'plat(avail=${c.isPlatformAvailable},resolved=${c.isPlatformResolved},active=${c.isPlatformActive})';
    }

    return <String>[
      'hasAPM=${state.hasAudioProcessingModule}',
      component('EC', state.echoCancellation),
      component('NS', state.noiseSuppression),
      component('AGC', state.autoGainControl),
      component('HPF', state.highPassFilter),
    ].join('\n');
  }
}
