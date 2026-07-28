import 'package:shared_preferences/shared_preferences.dart';

const String _kUserIdKey = 'background_gateway_snapshot_user_id';
const String _kApiBaseUrlKey = 'background_gateway_snapshot_api_base_url';
const String _kGatewayUrlKey = 'background_gateway_snapshot_gateway_url';

/// The only state handed into the background gateway isolate: just enough
/// to open a GatewayConnection without touching Riverpod, Drift, or any
/// other app provider that only exists in the main isolate.
class BackgroundGatewaySessionSnapshot {
  const BackgroundGatewaySessionSnapshot({
    required this.userId,
    required this.apiBaseUrl,
    required this.gatewayUrl,
  });

  final String userId;
  final String apiBaseUrl;
  final String? gatewayUrl;
}

Future<void> saveBackgroundGatewaySessionSnapshot(
  BackgroundGatewaySessionSnapshot snapshot,
) async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  await preferences.setString(_kUserIdKey, snapshot.userId);
  await preferences.setString(_kApiBaseUrlKey, snapshot.apiBaseUrl);
  if (snapshot.gatewayUrl == null) {
    await preferences.remove(_kGatewayUrlKey);
  } else {
    await preferences.setString(_kGatewayUrlKey, snapshot.gatewayUrl!);
  }
}

Future<BackgroundGatewaySessionSnapshot?> readBackgroundGatewaySessionSnapshot() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  final String? userId = preferences.getString(_kUserIdKey);
  final String? apiBaseUrl = preferences.getString(_kApiBaseUrlKey);
  if (userId == null || userId.isEmpty || apiBaseUrl == null || apiBaseUrl.isEmpty) {
    return null;
  }
  return BackgroundGatewaySessionSnapshot(
    userId: userId,
    apiBaseUrl: apiBaseUrl,
    gatewayUrl: preferences.getString(_kGatewayUrlKey),
  );
}

Future<void> clearBackgroundGatewaySessionSnapshot() async {
  final SharedPreferences preferences = await SharedPreferences.getInstance();
  await preferences.remove(_kUserIdKey);
  await preferences.remove(_kApiBaseUrlKey);
  await preferences.remove(_kGatewayUrlKey);
}
