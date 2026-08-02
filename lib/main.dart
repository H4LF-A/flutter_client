import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxer_app/app.dart';
import 'package:fluxer_app/core/bootstrap/display_refresh_rate_config.dart';
import 'package:fluxer_app/core/bootstrap/flutter_error_ui.dart';
import 'package:fluxer_app/core/bootstrap/image_cache_config.dart';
import 'package:fluxer_app/core/build/push_provider_assert.dart';
import 'package:fluxer_app/core/build/push_provider_guard.dart';
import 'package:fluxer_app/core/database/drift_stream_utils.dart';
import 'package:fluxer_app/core/observability/fluxer_observability.dart';
import 'package:fluxer_app/core/observability/observability_reporting_provider.dart';
import 'package:fluxer_app/core/platform/fluxer_platform.dart';
import 'package:fluxer_app/core/providers/app_startup_provider.dart';
import 'package:fluxer_app/core/providers/database_provider.dart';
import 'package:fluxer_app/core/push/fcm/fcm_entrypoint.dart';
import 'package:fluxer_app/core/push/services/unified_push_service.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

void _configureImagePicker() {
  if (kIsWeb || !Platform.isAndroid) {
    return;
  }
  final ImagePickerPlatform implementation = ImagePickerPlatform.instance;
  if (implementation is ImagePickerAndroid) {
    implementation.useAndroidPhotoPicker = true;
  }
}

void _runFluxerApp(ProviderContainer container) {
  runApp(
    ProviderScope(
      child: UncontrolledProviderScope(
        container: container,
        child: const FluxerApp(),
      ),
    ),
  );
}

void _configureFluxerErrorReporting() {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    FluxerObservability.instance.recordFlutterError(details);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    if (isDriftCancellation(error)) {
      return true;
    }
    FluxerObservability.instance.recordError(
      error,
      stackTrace: stack,
      source: 'platform_dispatcher',
    );
    FluxerObservability.instance.forceFlush();
    return false;
  };
}

Future<void> _bootstrapFluxer(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  configureFluxerDisplayRefreshRate();
  configureFluxerMobileDetection();
  configureFluxerImageCache();
  configureFluxerErrorUi();
  _configureFluxerErrorReporting();

  if (!kIsWeb) {
    FluxerObservability.instance.traceSync(
      'app.bootstrap.media_kit',
      MediaKit.ensureInitialized,
    );
  }

  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    // Without this, WebRTC initializes lazily with raw platform defaults
    // instead of declaring a proper two-way voice-communication audio
    // session (AudioAttributes usage/content type on Android, AVAudioSession
    // category/mode on iOS) - unlike apps that explicitly configure this,
    // which can affect platform audio routing decisions such as which
    // built-in microphone gets used.
    //
    // Deliberately using a custom Android config here instead of the plain
    // AndroidAudioSessionConfiguration.communication preset. Two things
    // going on:
    //
    // - usageType/contentType (the AudioAttributes actually attached to the
    //   record session) appear to be what fixes microphone routing.
    // - audioMode is forced to 'normal' rather than left unset. Leaving it
    //   unset does NOT mean "don't touch the mode": livekit_client's own
    //   native audio session manager (LKAudioSwitchManager, which explicitly
    //   disables flutter_webrtc's competing AudioSwitchManager on init and
    //   takes over the platform audio session itself) hardcodes
    //   MODE_IN_COMMUNICATION as its own default and (re-)applies it every
    //   time the mic publishes, independent of anything passed here unless
    //   explicitly overridden. MODE_IN_COMMUNICATION appears to make Android
    //   attach its own OS/OEM-level voice-processing chain outside WebRTC
    //   entirely, which ignores the app's noise-suppression tier and
    //   processes audio unconditionally - explicitly forcing 'normal' is the
    //   only way to actually keep the global AudioManager mode out of that
    //   state.
    //
    // Trade-off: flutter_webrtc's (now-disabled) AudioSwitchManager notes
    // some devices need MODE_IN_COMMUNICATION/MODE_IN_CALL for Bluetooth
    // mic/headset routing to work at all, so this may need revisiting if
    // Bluetooth audio breaks.
    await FluxerObservability.instance.traceAsync(
      'app.bootstrap.livekit_audio_session',
      () => LiveKitClient.initialize(
        initialAudioSessionOptions: const AudioSessionOptions.communication(
          android: AndroidAudioSessionConfiguration(
            usageType: AndroidAudioAttributesUsageType.voiceCommunication,
            contentType: AndroidAudioAttributesContentType.speech,
            audioMode: AndroidAudioMode.normal,
          ),
        ),
      ),
    );
  }

  final ProviderContainer container = ProviderContainer();
  await container.read(observabilityReportingProvider.notifier).load();
  FluxerObservability.instance.traceSync(
    'app.bootstrap.push_provider_assert',
    assertPushProviderBuildConfig,
  );
  await FluxerObservability.instance.traceAsync(
    'app.bootstrap.fcm',
    bootstrapFcmIfNeeded,
  );
  FluxerObservability.instance.traceSync(
    'app.bootstrap.image_picker',
    _configureImagePicker,
  );
  if (!kIsWeb && Platform.isAndroid) {
    FluxerObservability.instance.traceSync(
      'app.bootstrap.background_gateway_communication_port',
      FlutterForegroundTask.initCommunicationPort,
    );
  }
  final bool isUnifiedPushBackground =
      args.contains('--unifiedpush-bg') &&
      Platform.isAndroid &&
      PushProviderGuard.isUnifiedPush;
  if (isUnifiedPushBackground) {
    await FluxerObservability.instance.traceAsync(
      'app.bootstrap.unifiedpush_background',
      UnifiedPushService.ensureBackgroundInitialized,
    );
    return;
  }

  if (!kIsWeb && isFluxerDesktopOs) {
    await FluxerObservability.instance.traceAsync(
      'app.bootstrap.window',
      () async {
        await windowManager.ensureInitialized();

        const windowOptions = WindowOptions(
          size: Size(1280, 720),
          minimumSize: Size(200, 200),
          center: true,
          titleBarStyle: TitleBarStyle.hidden,
          title: 'Fluxer',
        );

        await windowManager.waitUntilReadyToShow(windowOptions, () async {
          await windowManager.show();
          await windowManager.focus();
        });
      },
    );
  }

  if (PushProviderGuard.isUnifiedPush) {
    FluxerObservability.instance.traceSync(
      'app.bootstrap.unifiedpush_database',
      () {
        UnifiedPushService.instance.attachDatabase(
          container.read(fluxerDatabaseProvider),
        );
      },
    );
  }

  FluxerObservability.instance.traceSync(
    'app.startup.provider',
    () => container.read(appStartupProvider),
  );
  FluxerObservability.instance.traceSync(
    'app.run',
    () => _runFluxerApp(container),
  );
}

Future<void> main(List<String> args) async {
  await runZonedGuarded<Future<void>>(
    () async {
      await _bootstrapFluxer(args);
    },
    (Object error, StackTrace stack) {
      if (isDriftCancellation(error)) {
        return;
      }
      FluxerObservability.instance.recordError(
        error,
        stackTrace: stack,
        source: 'zone',
      );
      FluxerObservability.instance.forceFlush();
      Error.throwWithStackTrace(error, stack);
    },
  );
}
