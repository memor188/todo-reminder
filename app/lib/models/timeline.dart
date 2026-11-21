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
