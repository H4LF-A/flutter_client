import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fluxer_app/core/gateway/background/background_gateway_battery_permission.dart';
import 'package:fluxer_app/core/gateway/background/background_gateway_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'background_gateway_preference_provider.g.dart';

const String _kBackgroundGatewayEnabledKey = 'background_gateway_enabled';

/// Whether this setting is meaningful on the current platform. Off-platform,
/// the toggle should be hidden entirely rather than shown disabled.
bool get isBackgroundGatewaySupportedPlatform => !kIsWeb && Platform.isAndroid;

// keepAlive: read from app_startup_provider so the service gets (re)started
// on every app launch if the preference was already on, regardless of
// whether the user ever opens the settings screen this session.
//
// The background service is started/stopped directly from this provider,
// not from app foreground/background lifecycle events. Reacting to
// lifecycle transitions turned out to be unreliable in practice: a system
// dialog or pulling down the notification shade briefly (and spuriously)
// looks like "backgrounded" to Flutter, while actually swiping the app away
// in the task switcher can kill the process before an async "start now"
// call finishes. Instead, once enabled, the service just runs continuously
// — a harmless redundant connection while the app is foregrounded, in
// exchange for never depending on catching an exact lifecycle transition.
@Riverpod(keepAlive: true)
class BackgroundGatewayPreference extends _$BackgroundGatewayPreference {
  @override
  bool build() {
    unawaited(_load());
    return false;
  }

  Future<void> _load() async {
    if (!isBackgroundGatewaySupportedPlatform) {
      return;
    }
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final bool enabled = preferences.getBool(_kBackgroundGatewayEnabledKey) ?? false;
    state = enabled;
    if (enabled) {
      await BackgroundGatewayService.instance.start();
    }
  }

  /// Returns the battery-optimization exemption outcome so the caller can
  /// surface a toast on denial; denial never blocks the toggle itself.
  Future<bool> setEnabled({required bool value}) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_kBackgroundGatewayEnabledKey, value);
    state = value;
    if (!value) {
      await BackgroundGatewayService.instance.stop();
      return true;
    }
    final bool batteryExemptionGranted =
        await requestBackgroundGatewayBatteryExemption();
    await BackgroundGatewayService.instance.start();
    return batteryExemptionGranted;
  }
}
