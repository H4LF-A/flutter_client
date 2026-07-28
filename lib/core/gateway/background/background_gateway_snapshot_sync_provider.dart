import 'dart:async';

import 'package:fluxer_app/core/gateway/background/background_gateway_session_snapshot.dart';
import 'package:fluxer_app/core/providers/active_instance_provider.dart';
import 'package:fluxer_app/core/router/fluxer_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'background_gateway_snapshot_sync_provider.g.dart';

/// Keeps the [BackgroundGatewaySessionSnapshot] persisted on disk in sync
/// with the currently signed-in user and instance, so it's ready to hand to
/// the background gateway isolate the moment the app is backgrounded.
@Riverpod(keepAlive: true)
void backgroundGatewaySnapshotSync(Ref ref) {
  void sync() {
    final String? userId = ref.read(currentUserIdProvider);
    if (userId == null || userId.isEmpty) {
      unawaited(clearBackgroundGatewaySessionSnapshot());
      return;
    }
    final String apiBaseUrl = ref.read(fluxerBaseUrlProvider);
    final String? gatewayUrl = ref.read(activeInstanceGatewayUrlProvider);
    unawaited(
      saveBackgroundGatewaySessionSnapshot(
        BackgroundGatewaySessionSnapshot(
          userId: userId,
          apiBaseUrl: apiBaseUrl,
          gatewayUrl: gatewayUrl,
        ),
      ),
    );
  }

  ref
    ..listen<String?>(currentUserIdProvider, (_, _) => sync())
    ..listen<String>(fluxerBaseUrlProvider, (_, _) => sync())
    ..listen<String?>(activeInstanceGatewayUrlProvider, (_, _) => sync());
  sync();
}
