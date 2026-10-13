/// Shared MCP plumbing: the [McpTool] value type plus the tiny JSON-schema
/// and payload helpers every tool file needs.
///
/// Split out of tools.dart so tool groups can live in their own files
/// (tools.dart = git-engine tools, tools_hosting.dart = platform tools)
/// without cross-file private-identifier tricks. Pure Dart, no Flutter.
library;

import 'dart:convert';

import '../engine/ffi.dart';

/// One MCP tool: name, schema and an async handler returning tool output
/// text (JSON string, diff text or a human message).
class McpTool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final Future<String> Function(Map<String, dynamic> args) run;
  const McpTool(this.name, this.description, this.inputSchema, this.run);

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
  };
}

// ------------------------- schema helpers -------------------------

Map<String, dynamic> obj(
  Map<String, dynamic> props, {
  List<String> required = const [],
}) => {'type': 'object', 'properties': props, 'required': required};

Map<String, dynamic> str(String desc, {List<String>? enum_}) => {
  'type': 'string',
  'description': desc,
  'enum': ?enum_,
};

Map<String, dynamic> boolean(String desc) => {
  'type': 'boolean',
  'description': desc,
};

Map<String, dynamic> integer(String desc) => {
  'type': 'integer',
  'description': desc,
};

Map<String, dynamic> listOf(String desc) => {
  'type': 'array',
  'items': {'type': 'string'},
  'description': desc,
};

// ------------------------ payload helpers ------------------------

/// Calls the Rust engine and returns either raw engine text (diffs) or
/// pretty-printed JSON.
Future<String> call(String method, Map<String, Object?> payload) async {
  final out = await RustLib.call(method, payload);
  return out is String ? out : const JsonEncoder.withIndent('  ').convert(out);
}

String path(Map<String, dynamic> a) => ((a['path'] as String?) ?? '').trim();

List<String> filePaths(Map<String, dynamic> a) => [
  for (final f in (a['files'] as List? ?? []))
    if (f is String) f,
];

int intArg(Map<String, dynamic> a, String key, int def) =>
    (a[key] as num?)?.toInt() ?? def;
