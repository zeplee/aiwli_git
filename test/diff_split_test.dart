import 'package:flutter_test/flutter_test.dart';
import 'package:aiwli_git/widgets/diff_view.dart';

DiffSection section(String header, List<String> lines) =>
    DiffSection(header: header, lines: lines);

void main() {
  group('DiffView.buildSplitRows (左右分栏切分)', () {
    test('context lines appear on both sides with matching numbers', () {
      final rows = DiffView.buildSplitRows(
        section('@@ -10,3 +10,3 @@', [' ctx-a', '+added-b', ' ctx-c']),
      );
      expect(rows.length, 3);
      expect(rows[0].left, 'ctx-a');
      expect(rows[0].right, 'ctx-a');
      expect(rows[0].leftNo, 10);
      expect(rows[0].rightNo, 10);
      // added line: right only, left blank
      expect(rows[1].left, '');
      expect(rows[1].right, 'added-b');
      expect(rows[1].leftOrigin, ' ');
      expect(rows[1].rightOrigin, '+');
      expect(rows[1].leftNo, isNull);
      expect(rows[1].rightNo, 11);
      // context after the addition advances both counters
      expect(rows[2].leftNo, 11);
      expect(rows[2].rightNo, 12);
    });

    test('removed lines take the left column only', () {
      final rows = DiffView.buildSplitRows(
        section('@@ -1,2 +1,2 @@', ['-gone', ' stays', '+new']),
      );
      expect(rows[0].left, 'gone');
      expect(rows[0].right, '');
      expect(rows[0].leftOrigin, '-');
      expect(rows[0].rightOrigin, ' ');
      expect(rows[0].leftNo, 1);
      expect(rows[0].rightNo, isNull);
      // removed line does not advance the right counter
      expect(rows[1].rightNo, 1);
      expect(rows[2].rightNo, 2);
      expect(rows[2].right, 'new');
    });

    test('"no newline" marker becomes a note row', () {
      final rows = DiffView.buildSplitRows(
        section('@@ -1 +1 @@', [
          '-old',
          '\\ No newline at end of file',
          '+new',
        ]),
      );
      expect(rows[1].note, isTrue);
      expect(rows[1].left, contains('No newline'));
    });

    test('counts default to 1 when the comma part is omitted', () {
      final rows = DiffView.buildSplitRows(section('@@ -3 +3 @@', [' x']));
      expect(rows[0].leftNo, 3);
      expect(rows[0].rightNo, 3);
    });
  });

  group('DiffView.parse (unified)', () {
    test('splits hunks and keeps file headers', () {
      const text =
          'diff --git a/f b/f\nindex 111..222 100644\n'
          '--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-a\n+b\n ctx\n';
      final sections = DiffView.parse(text);
      expect(sections.length, 1);
      expect(sections[0].fileHeader, contains('diff --git'));
      expect(sections[0].header, startsWith('@@'));
      expect(sections[0].lines, ['-a', '+b', ' ctx']);
    });

    test('multi-file patches split into per-file sections', () {
      const text =
          'diff --git a/a.txt b/a.txt\nindex 1..2 100644\n'
          '@@ -1 +1 @@\n-a1\n+a2\n'
          'diff --git a/b.txt b/b.txt\nindex 3..4 100644\n'
          '@@ -1 +1 @@\n-b1\n+b2\n';
      final sections = DiffView.parse(text);
      expect(sections.length, 2);
      expect(sections[0].fileHeader, contains('a.txt'));
      expect(sections[0].lines, ['-a1', '+a2']);
      expect(sections[1].fileHeader, contains('b.txt'));
      expect(sections[1].lines, ['-b1', '+b2']);
    });
  });
}
