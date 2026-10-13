/// SSH known_hosts management on the Dart side + the trust flow used by all
/// remote Git operations (fetch / push / pull / clone).
///
/// The Rust engine checks the presented SSH host key against the known_hosts
/// file whose path the caller passes; unknown hosts fail with the parseable
/// marker `SSH_HOST_UNKNOWN::host::ktype key` and changed keys with
/// `SSH_HOST_CHANGED::host::ktype key`. This module turns those markers into
/// a confirm dialog ("trust & remember" / "host key changed, update it"),
/// persists the decision, and retries the operation.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'prefs.dart';
import 'url_util.dart';

const _unknownMarker = 'SSH_HOST_UNKNOWN::';
const _changedMarker = 'SSH_HOST_CHANGED::';

class _SshMarker {
  final String host;
  final String keyLine; // "ktype base64key"
  _SshMarker(this.host, this.keyLine);
}

_SshMarker? _parseMarker(Object e, String marker) {
  final s = e.toString();
  final i = s.indexOf(marker);
  if (i < 0) return null;
  final rest = s.substring(i + marker.length);
  final sep = rest.indexOf('::');
  if (sep < 0) return null;
  final host = rest.substring(0, sep).trim();
  final key = rest.substring(sep + 2).trim();
  if (host.isEmpty) return null;
  return _SshMarker(host, key);
}

/// Path of the app-managed known_hosts file (app files dir; created lazily).
Future<String> knownHostsPath() => Prefs.instance.sshKnownHostsPath();

/// Remove every line mentioning [host] from the known_hosts file (used when
/// the user explicitly accepts a changed host key).
Future<void> forgetHost(String host) async {
  try {
    final f = File(await knownHostsPath());
    if (!await f.exists()) return;
    final kept = (await f.readAsString().then((t) => t.split('\n')))
        .where(
          (l) =>
              l.trim().isEmpty ||
              !l.trim().split(RegExp(r'[,\s]')).contains(host),
        )
        .join('\n');
    await f.writeAsString(
      kept.endsWith('\n') || kept.isEmpty ? kept : '$kept\n',
    );
  } catch (_) {
    // best effort — next trust dialog will handle persistent mismatches
  }
}

/// Marker exception: the user declined the SSH trust dialog (no error snack).
class SshDeclined implements Exception {
  @override
  String toString() => '已取消';
}

bool isSshDecline(Object e) => e is SshDeclined;

/// Runs [op] with SSH host-key guarding:
/// - unknown host → dialog → trust & remember → retry with accept=true
/// - changed key  → warning dialog → forget old key → retry
/// Throws [SshDeclined] when the user declines; rethrows unrelated errors so
/// callers keep their own error handling.
Future<T> runSshGuarded<T>(
  BuildContext context,
  Future<T> Function(bool acceptUnknown) op,
) async {
  try {
    return await op(false);
  } on Object catch (e) {
    final unknown = _parseMarker(e, _unknownMarker);
    if (unknown != null) {
      final ok = await _confirmTrust(
        context,
        '首次连接 ${unknown.host}',
        '尚未记录该主机的 SSH 密钥。\n\n类型与指纹：\n${_shortKey(unknown.keyLine)}\n\n'
            '信任并记住这台主机？（密钥会追加到本机 known_hosts）',
        danger: false,
      );
      if (ok != true || !context.mounted) throw SshDeclined();
      return await op(true); // engine remembers the key on success
    }
    final changed = _parseMarker(e, _changedMarker);
    if (changed != null) {
      final host = hostFromUrl(changed.host) ?? changed.host;
      final ok = await _confirmTrust(
        context,
        '${changed.host} 的主机密钥已变化',
        '之前记录的密钥与本次不一致。若你最近重建过服务器这可能是正常的；'
            '否则可能存在中间人风险。\n\n新密钥：\n${_shortKey(changed.keyLine)}\n\n'
            '更新本机记录并继续？',
        danger: true,
      );
      if (ok != true || !context.mounted) throw SshDeclined();
      await forgetHost(host);
      if (!context.mounted) throw SshDeclined();
      return await op(true);
    }
    rethrow;
  }
}

String _shortKey(String keyLine) {
  final parts = keyLine.split(' ');
  if (parts.length == 2 && parts[1].length > 44) {
    return '${parts[0]} ${parts[1].substring(0, 20)}…${parts[1].substring(parts[1].length - 12)}';
  }
  return keyLine;
}

Future<bool?> _confirmTrust(
  BuildContext context,
  String title,
  String body, {
  required bool danger,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: Text(body, style: const TextStyle(fontSize: 12.5)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: Colors.red.shade700)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(danger ? '更新并继续' : '信任并记住'),
        ),
      ],
    ),
  );
}

/// Guarded convenience for remote ops invoked from MCP / non-UI paths where no
/// dialog is possible: returns the engine error text untouched so the AI can
/// re-call with `acceptUnknownHost: true`.
bool isSshHostUnknownError(Object e) => _parseMarker(e, _unknownMarker) != null;
bool isSshHostChangedError(Object e) => _parseMarker(e, _changedMarker) != null;
