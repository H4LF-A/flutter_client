import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:fluxer_app/core/gateway/background/background_gateway_task_handler.dart';

/// Must stay a top-level function so R8/AOT doesn't tree-shake the isolate
/// entrypoint the foreground service callback needs.
@pragma('vm:entry-point')
void backgroundGatewayTaskEntrypoint() {
  FlutterForegroundTask.setTaskHandler(BackgroundGatewayTaskHandler());
}
