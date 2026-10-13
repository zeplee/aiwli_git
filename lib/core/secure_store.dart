import 'package:flutter/services.dart';

/// Android Keystore-backed encryption, reached through the `gitdeck/secure`
/// MethodChannel implemented in MainActivity.kt (no plugin dependency).
///
/// Contract: [encrypt] returns `base64(iv || ciphertext)` or null when the
/// channel is unavailable (e.g. desktop builds) — callers must fall back.
/// The AES key never leaves AndroidKeyStore; only ciphertext is persisted.
class SecureStore {
  static const _ch = MethodChannel('gitdeck/secure');

  static Future<String?> encrypt(String value) async {
    try {
      return await _ch.invokeMethod<String>('encrypt', {'value': value});
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<String?> decrypt(String blob) async {
    try {
      return await _ch.invokeMethod<String>('decrypt', {'blob': blob});
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
