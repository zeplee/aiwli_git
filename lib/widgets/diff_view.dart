import 'package:flutter/material.dart';

/// Unified diff renderer with two layouts:
/// - 统一视图：单列 +/-（窄屏友好）
/// - 左右对照：旧 / 新双列，同步滚动（宽屏友好）
/// Both share the same parser; the side-by-side splitter is a pure function
/// covered by unit tests. Optional per-hunk actions (block staging) work in
/// both layouts.
class DiffView extends StatefulWidget {
  /// Unified patch text (may contain headers from multiple files).
  final String patchText;
  final TextStyle Function(String origin)? lineStyle;

  /// hunk index → action row; when null, hunks render without action buttons.
  final Widget Function(BuildContext, int hunkIndex, String header)?
  hunkActions;
  final String? selectedFile;

  /// Start in side-by-side mode (user can still toggle when width allows).
  final bool startSplit;

  const DiffView({
    super.key,
    required this.patchText,
    this.lineStyle,
    this.hunkActions,
    this.selectedFile,
    this.startSplit = false,
  });

  @override
  State<DiffView> createState() => _DiffViewState();

  static TextStyle defaultStyle(String origin, ColorScheme cs) =>
      switch (origin) {
        '+' => TextStyle(
          color: Colors.green.shade700,
          fontSize: 11.5,
          fontFamily: 'monospace',
          height: 1.35,
        ),
        '-' => TextStyle(
          color: Colors.red.shade700,
          fontSize: 11.5,
          fontFamily: 'monospace',
          height: 1.35,
        ),
        '@' => TextStyle(
          color: cs.primary,
          fontSize: 11,
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
          height: 1.35,
        ),
        _ => TextStyle(
          color: cs.onSurface.withValues(alpha: 0.75),
          fontSize: 11.5,
          fontFamily: 'monospace',
          height: 1.35,
        ),
      };

  /// Parse patch text into sections: hunk list (file header tracked separately).
  /// A file's header lines attach to that file's first hunk section, so
  /// multi-file patches split cleanly and no empty-header section is emitted.
  static List<DiffSection> parse(String text) {
    final lines = text.split('\n');
    final sections = <DiffSection>[];
    DiffSection? cur;
    var pendingHeader = '';
    for (final l in lines) {
      if (l.startsWith('@@')) {
        cur = DiffSection(header: l, lines: [], fileHeader: pendingHeader);
        pendingHeader = '';
        sections.add(cur);
      } else if (cur == null) {
        if (l.startsWith('diff ') ||
            l.startsWith('index ') ||
            l.startsWith('---') ||
            l.startsWith('+++')) {
          pendingHeader = '$pendingHeader$l\n';
        }
        // ignore other preamble
      } else if (l.startsWith('diff ')) {
        // next file begins — the following index/---/+++ lines become its
        // pending header, and the next @@ opens a fresh section
        cur = null;
        pendingHeader = '$l\n';
      } else {
        if (l.isEmpty) continue; // trailing newline artifact of split()
        cur.lines.add(l);
      }
    }
    return sections;
  }

  /// Pure splitter: one [SplitRow] per rendered row of a hunk.
  static List<SplitRow> buildSplitRows(DiffSection section) {
    final m = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')
        .firstMatch(section.header);
    var left = int.tryParse(m?.group(1) ?? '');
    var right = int.tryParse(m?.group(3) ?? '');
    final rows = <SplitRow>[];
    for (final l in section.lines) {
      if (l.startsWith('\\')) {
        // "\ No newline at end of file" — render as a note row.
        rows.add(
          SplitRow(
            left: l,
            right: '',
            leftOrigin: '\\',
            rightOrigin: ' ',
            leftNo: null,
            rightNo: null,
            note: true,
          ),
        );
        continue;
      }
      final o = l.isEmpty ? ' ' : l[0];
      final t = l.isEmpty ? '' : l.substring(1);
      switch (o) {
        case '-':
          rows.add(
            SplitRow(
              left: t,
              right: '',
              leftOrigin: '-',
              rightOrigin: ' ',
              leftNo: left,
              rightNo: null,
            ),
          );
          if (left != null) left++;
        case '+':
          rows.add(
            SplitRow(
              left: '',
              right: t,
              leftOrigin: ' ',
              rightOrigin: '+',
              leftNo: null,
              rightNo: right,
            ),
          );
          if (right != null) right++;
        default:
          rows.add(
            SplitRow(
              left: t,
              right: t,
              leftOrigin: ' ',
              rightOrigin: ' ',
              leftNo: left,
              rightNo: right,
            ),
          );
          if (left != null) left++;
          if (right != null) right++;
      }
    }
    return rows;
  }
}

class _DiffViewState extends State<DiffView> {
  late bool _split = widget.startSplit;

  @override
  Widget build(BuildContext context) {
    if (widget.patchText.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Text('无差异', style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    final cs = Theme.of(context).colorScheme;
    final style = widget.lineStyle ?? (o) => DiffView.defaultStyle(o, cs);
    final sections = DiffView.parse(widget.patchText);
    return LayoutBuilder(
      builder: (context, c) {
        // Logical dp: a 1080-physical-px phone is only ~392dp wide, so the
        // threshold must stay low enough for split mode on ordinary phones.
        final canSplit = c.maxWidth >= 360;
        final split = canSplit && _split;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (canSplit)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                    onPressed: () => setState(() => _split = !_split),
                    icon: Icon(
                      split
                          ? Icons.view_agenda_outlined
                          : Icons.splitscreen_outlined,
                      size: 14,
                    ),
                    label: Text(split ? '统一视图' : '左右对照'),
                  ),
                ),
              ),
            for (var i = 0; i < sections.length; i++) ...[
              if (sections[i].fileHeader.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                  child: Text(
                    sections[i].fileHeader.trimRight(),
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: cs.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                color: cs.primary.withValues(alpha: 0.08),
                child: Text(sections[i].header, style: style('@')),
              ),
              if (split)
                _SplitHunk(section: sections[i], style: style)
              else
                ...sections[i].lines.map((l) {
                  final o = l.isEmpty ? ' ' : l[0];
                  final t = l.isEmpty ? '' : l.substring(1);
                  final bg = o == '+'
                      ? Colors.green.withValues(alpha: 0.07)
                      : o == '-'
                      ? Colors.red.withValues(alpha: 0.07)
                      : null;
                  return Container(
                    color: bg,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '$o$t',
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: style(o),
                    ),
                  );
                }),
              if (widget.hunkActions != null)
                widget.hunkActions!(context, i, sections[i].header),
            ],
          ],
        );
      },
    );
  }
}

// ============================ side-by-side ============================

/// One row of the side-by-side layout: old column / new column.
class SplitRow {
  final String left, right; // content without the sign char
  final String leftOrigin, rightOrigin; // ' ' | '+' | '-' | '\\' | ''
  final int? leftNo, rightNo;
  final bool note;
  SplitRow({
    required this.left,
    required this.right,
    required this.leftOrigin,
    required this.rightOrigin,
    required this.leftNo,
    required this.rightNo,
    this.note = false,
  });
}

Color? _rowBg(String origin, ColorScheme cs) => switch (origin) {
  '+' => Colors.green.withValues(alpha: 0.07),
  '-' => Colors.red.withValues(alpha: 0.07),
  _ => null,
};

class _SplitHunk extends StatelessWidget {
  final DiffSection section;
  final TextStyle Function(String origin) style;
  const _SplitHunk({required this.section, required this.style});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rows = DiffView.buildSplitRows(section);
    final gutterStyle = TextStyle(
      fontSize: 9.5,
      fontFamily: 'monospace',
      color: cs.onSurface.withValues(alpha: 0.35),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in rows)
          if (r.note)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                r.left,
                style: gutterStyle.copyWith(fontStyle: FontStyle.italic),
              ),
            )
          else
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _cell(
                    context,
                    bg: _rowBg(r.leftOrigin, cs),
                    gutter: r.leftNo?.toString() ?? '',
                    gutterStyle: gutterStyle,
                    text: r.left,
                    origin: r.leftOrigin,
                    style: style,
                  ),
                  Container(
                    width: 1,
                    color: cs.outlineVariant.withValues(alpha: 0.4),
                  ),
                  _cell(
                    context,
                    bg: _rowBg(r.rightOrigin, cs),
                    gutter: r.rightNo?.toString() ?? '',
                    gutterStyle: gutterStyle,
                    text: r.right,
                    origin: r.rightOrigin,
                    style: style,
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _cell(
    BuildContext context, {
    required Color? bg,
    required String gutter,
    required TextStyle gutterStyle,
    required String text,
    required String origin,
    required TextStyle Function(String) style,
  }) {
    return Expanded(
      child: Container(
        color: bg,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 38,
              child: Text(
                gutter,
                textAlign: TextAlign.right,
                style: gutterStyle,
              ),
            ),
            Expanded(
              child: Text(
                text.isEmpty ? '' : '$origin$text',
                softWrap: false,
                overflow: TextOverflow.clip,
                style: style(origin),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DiffSection {
  String header;
  String fileHeader;
  final List<String> lines;
  DiffSection({
    required this.header,
    required this.lines,
    this.fileHeader = '',
  });
}
