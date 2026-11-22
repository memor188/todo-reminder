import 'course.dart';
import 'event_item.dart';
import 'task.dart';

enum EntryType { course, event, task }

/// 显示层统一条目：数据层三张表分开，显示层在这里合并排序。
class TimelineEntry {
  const TimelineEntry({
    required this.key,
    required this.sourceId,
    required this.type,
    required this.title,
    required this.sortMinutes,
    required this.timeLabel,
    this.endMinutes,
    this.location,
    this.note,
    this.colorHex,
    this.done = false,
  });

  final String key;
  final int sourceId;
  final EntryType type;
  final String title;
  final int sortMinutes;

  /// 结束时刻（当天分钟数）。只给"有明确结束时间"的条目（目前是课程）。
  final int? endMinutes;
  final String timeLabel;
  final String? location;
  final String? note;
  final String? colorHex;
  final bool done;
}

DateTime parseDate(String value) => DateTime.parse(value);

String dateKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

/// 中文输入法常把半角连字符打成全角/长横线，统一归一化后再解析。
String normalizeDateText(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune >= 0xFF10 && rune <= 0xFF19) {
      buffer.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0xFF0D || rune == 0x2014 || rune == 0x2013) {
      buffer.write('-');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// 中文输入法常打出全角冒号/全角数字，统一归一化后再解析。
String normalizeTimeText(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune >= 0xFF10 && rune <= 0xFF19) {
      buffer.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0xFF1A || rune == 0xFF1B) {
      buffer.write(':');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

int? tryParseHm(String value) {
  final parts = normalizeTimeText(value).split(':');
  if (parts.length != 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  return hour * 60 + minute;
}

int parseHm(String value) => tryParseHm(value) ?? 0;

/// 无钟点任务默认提醒钟点（2026-11-21 定稿：当天 09:00，比 8 点更贴合早课）。
const int defaultTaskReminderMinutes = 9 * 60;

/// 算出任务该在哪一刻提醒。
/// - 有钟点：按钟点；
/// - 无钟点：当天 [defaultTaskReminderMinutes]；
/// - 钟点文本非法：返回 null（宁可不提醒，也不猜）。
DateTime? resolveTaskReminderAt(DateTime date, String? dueTime) {
  final int? minutes;
  if (dueTime == null || dueTime.trim().isEmpty) {
    minutes = defaultTaskReminderMinutes;
  } else {
    minutes = tryParseHm(dueTime);
  }
  if (minutes == null) return null;
  return DateTime(date.year, date.month, date.day, minutes ~/ 60, minutes % 60);
}

String hm(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
    '${(minutes % 60).toString().padLeft(2, '0')}';

/// 提前量默认值（V3 定稿）：事件要提前到场，任务到点做完即可。
const int defaultEventLeadMinutes = 15;
const int defaultTaskLeadMinutes = 0;

/// 可选的提前量档位，UI 下拉框和 AI 侧共用同一份。
const List<int> leadMinuteOptions = [0, 5, 10, 15, 30, 60];

/// 提前量的中文标签。0 显示「到点」，其余显示「提前 N 分钟」。
String leadLabel(int minutes) {
  if (minutes <= 0) return '到点提醒';
  if (minutes % 60 == 0) return '提前 ${minutes ~/ 60} 小时';
  return '提前 $minutes 分钟';
}

/// 通知正文。有提前量时说「还有 N 分钟」，否则说「到点了」——
/// 设了提前 30 分钟却弹「到点了」，用户会以为时间到了。
String reminderBody(String title, int leadMinutes) {
  if (leadMinutes <= 0) return '到点了：$title';
  if (leadMinutes % 60 == 0) return '还有 ${leadMinutes ~/ 60} 小时：$title';
  return '还有 $leadMinutes 分钟：$title';
}

/// 算最终该在什么时刻弹提醒。
///
/// 三个分支：
/// - 事件本身已经过去 → null，不提醒；
/// - 事件时刻减去提前量仍在未来 → 按提前量提醒；
/// - 减完已经过去、但事件还没到 → 退化为「立刻提醒」。
///
/// 第三条是刻意留的兜底：用户 14:30 建了一条「今天 15:00 考试，提前 60 分钟」，
/// 提前量已经无从谈起，但这时恰恰是最该立刻提醒的时刻，静默丢掉不合理。
DateTime? resolveRemindAt({
  required DateTime eventTime,
  required int leadMinutes,
  required DateTime now,
}) {
  if (!eventTime.isAfter(now)) return null;
  final lead = eventTime.subtract(
    Duration(minutes: leadMinutes <= 0 ? 0 : leadMinutes),
  );
  // +5 秒是为了让下游的 schedule() 一定落在未来（它对过去的时刻会抛错）。
  return lead.isAfter(now) ? lead : now.add(const Duration(seconds: 5));
}

bool _matchesParity(Course course, DateTime day) {
  if (course.weekParity == 0) return true;
  final weekIndex =
      day.difference(parseDate(course.semesterStart)).inDays ~/ 7 + 1;
  final isOdd = weekIndex.isOdd;
  return course.weekParity == 1 ? isOdd : !isOdd;
}

/// 把周期课程在指定日期展开成一个显示条目。
List<TimelineEntry> expandCourse(Course course, DateTime day) {
  final target = DateTime(day.year, day.month, day.day);
  final start = parseDate(course.semesterStart);
  final end = parseDate(course.semesterEnd);
  if (target.isBefore(start) || target.isAfter(end)) return const [];
  if (target.weekday != course.dayOfWeek) return const [];
  if (!_matchesParity(course, target)) return const [];

  final begin = parseHm(course.startTime);
  return [
    TimelineEntry(
      key: 'course_${course.id}_${dateKey(target)}',
      sourceId: course.id ?? 0,
      type: EntryType.course,
      title: course.title,
      sortMinutes: begin,
      timeLabel: '${course.startTime}–${course.endTime}',
      endMinutes: parseHm(course.endTime),
      location: course.location,
      note: course.color,
      colorHex: course.color,
    ),
  ];
}

/// 合并三类数据并按时间排序，得到某一天的日程时间线。
List<TimelineEntry> buildTimeline({
  required DateTime day,
  required List<Course> courses,
  required List<EventItem> events,
  required List<TaskItem> tasks,
  bool includeDone = false,
}) {
  final target = DateTime(day.year, day.month, day.day);
  final key = dateKey(target);
  final result = <TimelineEntry>[];

  for (final course in courses) {
    result.addAll(expandCourse(course, target));
  }
  for (final event in events) {
    if (event.done && !includeDone) continue;
    final start = DateTime.parse(event.startAt);
    if (dateKey(start) != key) continue;
    result.add(
      TimelineEntry(
        key: 'event_${event.id}',
        sourceId: event.id ?? 0,
        type: EntryType.event,
        title: event.title,
        sortMinutes: start.hour * 60 + start.minute,
        timeLabel:
            '${start.hour.toString().padLeft(2, '0')}:'
            '${start.minute.toString().padLeft(2, '0')}',
        location: event.location,
        note: event.note,
      ),
    );
  }
  for (final task in tasks) {
    if (task.done && !includeDone) continue;
    if (task.dueDate != key) continue;
    final minutes = task.dueTime == null ? 24 * 60 : parseHm(task.dueTime!);
    result.add(
      TimelineEntry(
        key: 'task_${task.id}',
        sourceId: task.id ?? 0,
        type: EntryType.task,
        title: task.title,
        sortMinutes: minutes,
        timeLabel: task.dueTime ?? '全天',
        location: task.location,
        note: task.note,
      ),
    );
  }

  result.sort((a, b) => a.sortMinutes.compareTo(b.sortMinutes));
  return result;
}

class _Span {
  _Span(this.entry, this.start, this.end);
  final TimelineEntry entry;
  final int start;
  final int end;
}

/// 课表网格里一条条目的位置（分钟为单位，渲染层再换算成像素）。
class GridSlot {
  const GridSlot({
    required this.entry,
    required this.startMinutes,
    required this.endMinutes,
    required this.column,
    required this.columns,
  });

  final TimelineEntry entry;
  final int startMinutes;
  final int endMinutes;

  /// 组内第几列（0 起）与组内总列数，用来并排显示重叠条目。
  final int column;
  final int columns;
}

/// 把一天的时间线算成网格占位。
///
/// - 有 [TimelineEntry.endMinutes]（课程）按真实区间铺；
/// - 没有的（事件/任务）按 [defaultDurationMinutes] 撑开，太短则给 [minDurationMinutes]；
/// - 时间区间有重叠的条目并排显示，宽度平分；不重叠的各占整列。
List<GridSlot> layoutDay(
  List<TimelineEntry> entries, {
  int defaultDurationMinutes = 60,
  int minDurationMinutes = 20,
}) {
  final sorted = [...entries]
    ..sort((a, b) => a.sortMinutes.compareTo(b.sortMinutes));

  final slots = <GridSlot>[];
  var group = <_Span>[];
  var groupEnd = -1;

  void flush() {
    if (group.isEmpty) return;
    final columns = group.length;
    for (var i = 0; i < group.length; i++) {
      final span = group[i];
      slots.add(
        GridSlot(
          entry: span.entry,
          startMinutes: span.start,
          endMinutes: span.end,
          column: i,
          columns: columns,
        ),
      );
    }
    group = <_Span>[];
  }

  for (final entry in sorted) {
    final start = entry.sortMinutes;
    final rawEnd = entry.endMinutes;
    final end = rawEnd != null && rawEnd > start
        ? rawEnd
        : start + defaultDurationMinutes;
    final safeEnd = end - start < minDurationMinutes
        ? start + minDurationMinutes
        : end;
    final span = _Span(entry, start, safeEnd);

    if (group.isNotEmpty && span.start >= groupEnd) {
      flush();
      groupEnd = -1;
    }
    group.add(span);
    if (span.end > groupEnd) groupEnd = span.end;
  }
  flush();

  return slots;
}
