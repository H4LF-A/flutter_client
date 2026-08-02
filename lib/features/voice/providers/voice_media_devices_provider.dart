import 'package:fluxer_app/features/voice/domain/voice_settings_state.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'voice_media_devices_provider.g.dart';

class VoiceMediaDeviceOption {
  const VoiceMediaDeviceOption({
    required this.deviceId,
    required this.label,
    required this.kind,
  });

  final String deviceId;
  final String label;
  final String kind;
}

class VoiceMediaDevicesState {
  const VoiceMediaDevicesState({
    this.audioInputs = const <VoiceMediaDeviceOption>[],
    this.audioOutputs = const <VoiceMediaDeviceOption>[],
    this.videoInputs = const <VoiceMediaDeviceOption>[],
    this.isLoading = false,
  });

  final List<VoiceMediaDeviceOption> audioInputs;
  final List<VoiceMediaDeviceOption> audioOutputs;
  final List<VoiceMediaDeviceOption> videoInputs;
  final bool isLoading;

  VoiceMediaDevicesState copyWith({
    List<VoiceMediaDeviceOption>? audioInputs,
    List<VoiceMediaDeviceOption>? audioOutputs,
    List<VoiceMediaDeviceOption>? videoInputs,
    bool? isLoading,
  }) {
    return VoiceMediaDevicesState(
      audioInputs: audioInputs ?? this.audioInputs,
      audioOutputs: audioOutputs ?? this.audioOutputs,
      videoInputs: videoInputs ?? this.videoInputs,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

List<VoiceMediaDeviceOption> _withDefaultOption(
  List<VoiceMediaDeviceOption> devices,
) {
  return <VoiceMediaDeviceOption>[
    const VoiceMediaDeviceOption(
      deviceId: kDefaultVoiceDeviceId,
      label: '',
      kind: '',
    ),
    ...devices,
  ];
}

VoiceMediaDeviceOption _mapDevice(MediaDevice device) {
  return VoiceMediaDeviceOption(
    deviceId: device.deviceId,
    label: device.label,
    kind: device.kind,
  );
}

VoiceMediaDeviceOption _mapAndroidOutputDevice(Map<String, dynamic> device) {
  return VoiceMediaDeviceOption(
    deviceId: (device['deviceId'] as String?) ?? '',
    label: (device['label'] as String?) ?? '',
    kind: 'audiooutput',
  );
}

@Riverpod(keepAlive: true)
class VoiceMediaDevices extends _$VoiceMediaDevices {
  @override
  VoiceMediaDevicesState build() {
    return const VoiceMediaDevicesState();
  }

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true);
    try {
      final List<MediaDevice> devices = await Hardware.instance
          .enumerateDevices();
      final List<VoiceMediaDeviceOption> audioInputs = devices
          .where((MediaDevice device) => device.kind == 'audioinput')
          .map(_mapDevice)
          .toList();
      // On Android, flutter_webrtc's own output-device enumeration always
      // returns empty (this app disables flutter_webrtc's competing
      // AudioSwitchManager in favor of LiveKit's own) - ask LiveKit's audio
      // manager directly instead, which reflects the manager actually in
      // control of routing. A no-op, empty-returning call on other platforms.
      final List<Map<String, dynamic>> androidOutputDevices =
          await AudioManager.instance.getAndroidOutputDevices();
      final List<VoiceMediaDeviceOption> audioOutputs =
          androidOutputDevices.isNotEmpty
          ? androidOutputDevices.map(_mapAndroidOutputDevice).toList()
          : devices
                .where((MediaDevice device) => device.kind == 'audiooutput')
                .map(_mapDevice)
                .toList();
      final List<VoiceMediaDeviceOption> videoInputs = devices
          .where((MediaDevice device) => device.kind == 'videoinput')
          .map(_mapDevice)
          .toList();
      state = VoiceMediaDevicesState(
        audioInputs: _withDefaultOption(audioInputs),
        audioOutputs: _withDefaultOption(audioOutputs),
        videoInputs: _withDefaultOption(videoInputs),
      );
    } on Object {
      state = state.copyWith(isLoading: false);
    }
  }
}
