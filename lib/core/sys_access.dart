import 'package:flutter/services.dart';

/// Storage-access state + deep link to the system settings page, through the
/// `gitdeck/sys` MethodChannel in MainActivity.kt (Android only).
class SysAccess {
  static const _ch = MethodChannel('gitdeck/sys');

  /// Returns 'granted' | 'denied', or null when the channel is unavailable
  /// (non-Android builds — callers should hide the storage banner).
  static Future<String?> state() async {
    try {
      return await _ch.invokeMethod<String>('storageAccessState');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Opens the system page where "All files access" can be granted.
  static Future<void> openSettings() async {
    try {
      await _ch.invokeMethod('openStorageSettings');
    } catch (_) {}
  }

  /// Starts/stops the foreground service that keeps the process (and the MCP
  /// server) alive while the app is backgrounded or the screen is locked.
  static Future<void> mcpKeepAlive(bool keep) async {
    try {
      await _ch.invokeMethod('mcpKeepAlive', {'keep': keep});
    } catch (_) {}
  }
}
