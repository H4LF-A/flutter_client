import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:fluxer_app/core/providers/app_ui_lifecycle_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'background_gateway_foreground_state_sync_provider.g.dart';

/// Tells the background gateway isolate (if running) whether the app is
/// currently foreground, so it can suppress notifications for messages the
/// user is already seeing live in the UI. The service now runs continuously
/// whenever the feature is enabled — not just while backgrounded — so this
/// is the only thing standing between "connected" and "would double-notify".
@Riverpod(keepAlive: true)
void backgroundGatewayForegroundStateSync(Ref ref) {
  ref.listen<bool>(appUiForegroundProvider, (bool? previous, bool next) {
    FlutterForegroundTask.sendDataToTask(next);
  }, fireImmediately: true);
}
