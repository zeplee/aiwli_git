import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aiwli_git/mcp/tools.dart';

void main() {
  test('jsonEncode tools/list payload', () {
    final body = {
      'jsonrpc': '2.0',
      'id': 3,
      'result': {
        'tools': [for (final t in mcpTools) t.toJson()],
      },
    };
    final s = jsonEncode(body);
    expect(s.length, greaterThan(1000));
  });
}
