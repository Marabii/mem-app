import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart side of `ServerForegroundService.kt`.
///
/// The HTTP server runs on this isolate, so it only needs Android to leave the
/// process alone: a foreground service with a wake lock and a Wi-Fi lock is
/// what stops the screen going off from freezing the isolate and cutting the
/// socket.
///
/// Every call is a no-op off Android (tests, desktop), where there is no
/// service to talk to and nothing suspending the process either.
class ServerKeepAlive {
  ServerKeepAlive({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('com.memapp.app/server');

  final MethodChannel _channel;

  /// Called when the user taps "Stop" on the service's notification, or when
  /// the task is swiped away with the engine still alive.
  VoidCallback? onStopRequested;

  bool get _supported => !kIsWeb && Platform.isAndroid;

  void listen() {
    if (!_supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') onStopRequested?.call();
      return null;
    });
  }

  /// Starts the service. Returns false when the platform refused — the server
  /// itself still works, it just will not outlive the screen.
  Future<bool> start(String url) async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('start', {'url': url}) ?? false;
    } catch (e) {
      debugPrint('MemApp: could not start the keep-alive service ($e)');
      return false;
    }
  }

  Future<void> stop() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      debugPrint('MemApp: could not stop the keep-alive service ($e)');
    }
  }

  Future<bool> isRunning() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Android's battery optimisation settings. Foreground services
  /// survive Doze, but several manufacturers ship their own killers on top,
  /// and this is where the user exempts the app from those.
  Future<bool> openBatterySettings() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('openBatterySettings') ?? false;
    } catch (e) {
      debugPrint('MemApp: could not open battery settings ($e)');
      return false;
    }
  }
}
