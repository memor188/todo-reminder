import 'dart:typed_data';

import '../models/period_table.dart';
import '../models/week_set.dart';
import 'ai_service.dart' show AiCourseDraft;
import 'xls_reader.dart';

/// 把教务系统导出的 `.xls` 课表直接读成课程草稿。
///
/// 为什么不让 AI 读这个文件：`.xls` 是二进制，AI 看不了；而它的结构又是
/// 高度规整的（大节 × 星期 的网格，每格几段「课名/教师/周次/地点」），
/// 本地解析比让模型猜更准，也不花钱、不联网。
///
/// 产出的 [AiCourseDraft] 与 AI 路径完全同构，导入页不用分叉。
///
/// 真实文件（汕大 2026-2027-1）的形状：
/// ```
/// 汕头大学 xxx 学生个人课表
/// 学年学期：...  班级：...     ← 前两行是表头，跳过
///       星期一 星期二 ...       ← 星期行
/// 一(01,02)  ...空...  ...课...  ← 每行一个大节，格子内是课块
/// 二(03,04,05) ...
/// ```
/// 单元格里的课块用空行分隔，每块四行：课名 / 教师 / `周次([周])[节次]` / 地点。
List<AiCourseDraft> coursesFromXlsSheet(XlsSheet sheet, PeriodTable table) {
  if (table.isEmpty) return const [];
  final drafts = <AiCourseDraft>[];

  final dayColumns = _dayColumns(sheet);
  if (dayColumns.isEmpty) return const [];

  final headerRow = dayColumns.values.first.row;
  for (var row = headerRow + 1; row < sheet.rowCount; row++) {
    final bigSection = _periodNumbers(sheet.cell(row, 0));
    for (final entry in dayColumns.entries) {
      final day = entry.key;
      final text = sheet.cell(row, entry.value.col);
      if (text.trim().isEmpty) continue;
      for (final block in _blocks(text)) {
        final draft = _draftFromBlock(
          block,
          dayOfWeek: day,
          fallbackPeriods: bigSection,
          table: table,
        );
        if (draft != null) drafts.add(draft);
      }
    }
  }
  return mergeSameCourse(drafts);
}

class _Column {
  const _Column(this.row, this.col);
  final int row;
  final int col;
}

/// 找「星期几」表头行，返回 {1..7: 列号}。
Map<int, _Column> _dayColumns(XlsSheet sheet) {
  const names = {
    '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7,
  };
  for (var row = 0; row < sheet.rowCount; row++) {
    final found = <int, _Column>{};
    for (var col = 0; col < sheet.colCount; col++) {
      final text = sheet.cell(row, col).replaceAll(RegExp(r'\s'), '');
      if (!text.contains('星期') && !text.startsWith('周')) continue;
      final tail = text.replaceAll('星期', '').replaceAll('周', '');
      final day = names[tail];
      if (day != null) found[day] = _Column(row, col);
    }
    // 至少认出 5 天才当成表头，避免把课程名里的「周一」误当表头
    if (found.length >= 5) return found;
  }
  return const {};
}

/// 从「一(01,02)」里抠出节次序号 [1, 2]。
List<int> _periodNumbers(String cell) {
  final match = RegExp(r'[（(]([\d,\s，]+)[）)]').firstMatch(cell);
  if (match == null) return const [];
  return _numbersFrom(match.group(1)!);
}

List<int> _numbersFrom(String raw) {
  final out = <int>[];
  for (final part in raw.split(RegExp(r'[,，\s]+'))) {
    final value = int.tryParse(part.trim());
    if (value != null && value >= 1) out.add(value);
  }
  return out;
}

/// 单元格文本 → 课块（每块若干非空行）。空行是块分隔符。
List<List<String>> _blocks(String text) {
  final blocks = <List<String>>[];
  var current = <String>[];
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      if (current.isNotEmpty) {
        blocks.add(current);
        current = <String>[];
      }
      continue;
    }
    current.add(line);
  }
  if (current.isNotEmpty) blocks.add(current);
  return blocks;
}

/// `周次([周])[节次]` 这一行，例如 `4,6,8,10([周])[01-02节]`。
final RegExp _weekLine = RegExp(r'^([\d,，\-]+)\s*\(\[周\]\)\s*\[([\d\-]+)节\]$');

AiCourseDraft? _draftFromBlock(
  List<String> lines, {
  required int dayOfWeek,
  required List<int> fallbackPeriods,
  required PeriodTable table,
}) {
  if (lines.isEmpty) return null;

  var weekIndex = -1;
  Match? match;
  for (var i = 0; i < lines.length; i++) {
    final candidate = _weekLine.firstMatch(lines[i]);
    if (candidate != null) {
      weekIndex = i;
      match = candidate;
      break;
    }
  }

  final title = _cleanTitle(lines.first);
  if (title.isEmpty) return null;

  // 块里没有周次行：可能是「课名/教师/地点」这类缺字段的格子，仍按大节节次收下
  final weeksRaw = match?.group(1);
  final periodRaw = match?.group(2);
  final periods = periodRaw == null
      ? fallbackPeriods
      : _numbersFrom(periodRaw.split('-').join(','));

  String? teacher;
  String? location;
  if (weekIndex >= 0) {
    if (weekIndex >= 2) teacher = _cleanField(lines[1]);
    if (weekIndex + 1 < lines.length) {
      location = _cleanField(lines[weekIndex + 1]);
    }
  } else if (lines.length >= 2) {
    teacher = _cleanField(lines[1]);
    if (lines.length >= 3) location = _cleanField(lines[2]);
  }

  final span = periods.isEmpty ? null : table.spanByNumbers(periods);
  final weeks = _normalizeWeeks(weeksRaw);

  return AiCourseDraft(
    title: title,
    dayOfWeek: dayOfWeek,
    period: periods.isEmpty ? null : periods.join('-'),
    startTime: span?.start,
    endTime: span?.end,
    location: location,
    teacher: teacher,
    weeks: weeks,
    weekParity: 0,
    unresolvedReason: span == null
        ? (periods.isEmpty ? '没读出节次' : '第 ${periods.join('/')} 节超出作息表行数')
        : null,
  );
}

String _cleanTitle(String raw) => raw
    .replaceAll(RegExp(r'^[\s　•·]+'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String? _cleanField(String raw) {
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.isEmpty ? null : text;
}

String? _normalizeWeeks(String? raw) {
  if (raw == null) return null;
  final parsed = WeekSet.tryParse(raw);
  if (parsed == null) return null;
  return WeekSet.format(parsed.weeks);
}

/// 同一门课被拆成多块（不同教师、不同周段）时合并成一条。
///
/// 真实例子：线性代数 3-12,15-18 周陈哲 + 13-14 周邬恩信，地点相同 →
/// 合成 `3-18` 周一条。教师留第一位的。
List<AiCourseDraft> mergeSameCourse(List<AiCourseDraft> drafts) {
  final merged = <String, AiCourseDraft>{};
  final order = <String>[];
  for (final draft in drafts) {
    final key = [
      draft.title,
      draft.dayOfWeek,
      draft.startTime ?? draft.period ?? '?',
      draft.endTime ?? '',
      draft.location ?? '',
    ].join('|');
    final existing = merged[key];
    if (existing == null) {
      merged[key] = draft;
      order.add(key);
      continue;
    }
    final union = _unionWeeks(existing.weeks, draft.weeks);
    merged[key] = AiCourseDraft(
      title: existing.title,
      dayOfWeek: existing.dayOfWeek,
      period: existing.period,
      startTime: existing.startTime,
      endTime: existing.endTime,
      location: existing.location,
      note: existing.note,
      teacher: existing.teacher ?? draft.teacher,
      weeks: union,
      weekParity: existing.weekParity,
      unresolvedReason: existing.unresolvedReason,
      raw: existing.raw,
    );
  }
  return [for (final key in order) merged[key]!];
}

String? _unionWeeks(String? a, String? b) {
  if (a == null && b == null) return null;
  final left = WeekSet.tryParse(a);
  final right = WeekSet.tryParse(b);
  if (left == null && right == null) return null;
  final weeks = <int>{
    ...?left?.weeks,
    ...?right?.weeks,
  };
  if (weeks.isEmpty) return null;
  return WeekSet.format(weeks);
}

/// 这些扩展名的文件按纯文本读，交给 AI 解析（csv / tsv / txt / md / html 都行）。
bool isTextTimetable(String fileName) {
  final lower = fileName.toLowerCase();
  return const ['.csv', '.tsv', '.txt', '.md', '.html', '.htm']
      .any(lower.endsWith);
}

/// 读纯文本表格。UTF-8 优先，GBK 之类解不出时按 latin-1 兜底
/// （教务系统偶尔导出 GBK，强解会乱码，宁可让用户看到乱码再手改）。
String textFromFile(Uint8List bytes) => decodeUtf8OrLatin(bytes);
