import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Best-effort request for the battery-optimization exemption the background
/// gateway service needs to survive Doze. Declining doesn't block anything —
/// it just makes Android more likely to kill the service under Doze.
Future<bool> requestBackgroundGatewayBatteryExemption() async {
  if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
    return true;
  }
  await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  return FlutterForegroundTask.isIgnoringBatteryOptimizations;
}
