import 'dart:convert';
import 'dart:io';

// Diagnostics go straight to logcat (tag: flutter) — kept deliberately for
// on-device troubleshooting; ignore the print lint for this file.
// ignore_for_file: avoid_print

import '../core/prefs.dart';
import '../core/sys_access.dart';
import '../core/version.dart';
import '../widgets/dialogs.dart';
import 'tools.dart';

/// Local MCP server over Streamable HTTP (POST /mcp, JSON-RPC 2.0).
///
/// Binds to loopback only: AI tools on the same device (e.g. Kelivo) connect
/// to `http://127.0.0.1:<port>/mcp` and call the Git engine tools.
/// Stateless: no Mcp-Session-Id is issued; each POST is handled independently.
/// GET returns 405 (no SSE support), OPTIONS answers CORS preflight.
class McpServer {
  static final McpServer instance = McpServer._();
  McpServer._();

  HttpServer? _srv;
  int _port = 8613;
  String _token = '';
  String? error;

  bool get running => _srv != null;
  int get port => _port;
  String get url => 'http://127.0.0.1:$_port/mcp';

  /// Starts the server when the saved pref says enabled (called from main()).
  Future<void> startIfEnabled() async {
    if (running) return;
    if (await Prefs.instance.mcpEnabled()) {
      await start(
        await Prefs.instance.mcpPort(),
        await Prefs.instance.mcpToken(),
      );
    }
  }

  Future<void> start(int port, String token) async {
    await stop();
    _port = port;
    _token = token;
    error = null;
    try {
      final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      srv.listen(_onRequest, onError: (Object _) {});
      _srv = srv;
      await SysAccess.mcpKeepAlive(true); // FGS: survive background freeze
    } catch (e) {
      _srv = null;
      error = '端口 $port 启动失败：$e';
    }
  }

  Future<void> stop() async {
    final s = _srv;
    _srv = null;
    try {
      await s?.close(force: true);
    } catch (_) {}
    await SysAccess.mcpKeepAlive(false);
  }

  Future<void> _onRequest(HttpRequest req) async {
    try {
      if (req.method == 'OPTIONS') return _json(req, 200);
      if (req.uri.path != '/mcp') {
        return _json(req, 404, _rpcErr(null, -32601, 'not found'));
      }
      if (_token.isNotEmpty && !_authOk(req)) {
        return _json(req, 401, _rpcErr(null, -32001, '未授权：令牌不匹配'));
      }
      if (req.method != 'POST') {
        req.response.headers.set('Allow', 'POST');
        return _json(
          req,
          405,
          _rpcErr(null, -32601, '仅支持 POST（MCP Streamable HTTP）'),
        );
      }
      final body = await utf8.decoder.bind(req).join();
      print('[MCP] ${req.method} ${req.uri.path} body=${body.length}');
      dynamic msg;
      try {
        msg = jsonDecode(body);
      } catch (_) {
        return _json(req, 400, _rpcErr(null, -32700, 'JSON 解析失败'));
      }
      if (msg is List) {
        final out = <Map<String, dynamic>>[];
        for (final m in msg) {
          final r = await _handleMessage(m);
          if (r != null) out.add(r);
        }
        return out.isEmpty ? _json(req, 202) : _json(req, 200, out);
      }
      final r = await _handleMessage(msg);
      return r == null ? _json(req, 202) : _json(req, 200, r);
    } catch (e, st) {
      print('[MCP] onRequest-err: $e');
      print('[MCP] $st');
      _json(req, 500, _rpcErr(null, -32603, 'internal error: $e'));
    }
  }

  bool _authOk(HttpRequest req) {
    final auth = req.headers.value('authorization');
    if (auth == 'Bearer $_token') return true;
    return req.headers.value('x-mcp-token') == _token;
  }

  /// Returns a JSON-RPC response, or null for notifications (HTTP 202).
  Future<Map<String, dynamic>?> _handleMessage(dynamic msg) async {
    if (msg is! Map) return _rpcErr(null, -32600, 'invalid request');
    final id = msg['id'];
    final method = msg['method'] as String?;
    if (method == null) return _rpcErr(id, -32600, 'missing method');
    switch (method) {
      case 'initialize':
        final pv = ((msg['params'] as Map?)?['protocolVersion']) as String?;
        return _rpcOk(id, {
          'protocolVersion': pv ?? '2024-11-05',
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': 'AiwliGit', 'version': appVersion},
        });
      case 'notifications/initialized':
      case 'initialized':
        return null;
      case 'ping':
        return _rpcOk(id, {});
      case 'tools/list':
        return _rpcOk(id, {
          'tools': [for (final t in mcpTools) t.toJson()],
        });
      case 'tools/call':
        final params = (msg['params'] as Map?) ?? {};
        final tool = toolByName(params['name'] as String? ?? '');
        if (tool == null) {
          return _rpcErr(id, -32602, "unknown tool: ${params['name']}");
        }
        final args = Map<String, dynamic>.from(
          (params['arguments'] as Map?) ?? {},
        );
        try {
          print('[MCP] tool start: ${tool.name}');
          final out = await tool.run(args);
          print('[MCP] tool done: ${tool.name} len=${out.length}');
          return _rpcOk(id, {
            'content': [
              {'type': 'text', 'text': out},
            ],
            'isError': false,
          });
        } catch (e) {
          return _rpcOk(id, {
            'content': [
              {'type': 'text', 'text': friendlyError(e)},
            ],
            'isError': true,
          });
        }
      default:
        if (id == null) return null; // unknown notification → ignore
        return _rpcErr(id, -32601, 'method not found: $method');
    }
  }

  Map<String, dynamic> _rpcOk(dynamic id, Map<String, dynamic> result) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  };

  Map<String, dynamic> _rpcErr(dynamic id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };

  void _json(HttpRequest req, int status, [Object? body]) {
    try {
      req.response.statusCode = status;
      // charset=utf-8 is REQUIRED: without it Dart's HttpServer encodes the
      // body as Latin-1 and any non-ASCII text (中文) makes write() throw
      // "Contains invalid characters" — silently swallowed → empty response.
      req.response.headers.set(
        'Content-Type',
        'application/json; charset=utf-8',
      );
      req.response.headers.set('Access-Control-Allow-Origin', '*');
      if (body != null) {
        final enc = jsonEncode(body);
        print('[MCP] respond $status enc=${enc.length}');
        req.response.write(enc);
      } else {
        print('[MCP] respond $status no-body');
      }
    } catch (e, st) {
      print('[MCP] respond-err $status: $e');
      print('[MCP] $st');
    }
    try {
      req.response.close();
    } catch (_) {}
  }
}
