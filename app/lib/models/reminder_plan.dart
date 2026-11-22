import 'course.dart';
import 'timeline.dart';

/// 课程提醒的默认提前量。
///
/// 事件默认提前 15 分钟（要提前到场办事），任务默认到点（当天做完即可），
/// 课程取中间值 10 分钟——从宿舍楼下走到教学楼正好够。
const int defaultCourseLeadMinutes = 10;

/// 课程提醒只排未来这么多周。
///
/// 课程是周期规则，但 Android 的重复闹钟（`matchDateTimeComponents`）只能
/// 表达「每周同一时刻」，表达不了「单双周」也表达不了「学期结束就停」。
/// 所以这里不用重复闹钟，而是把未来若干周的真实课时逐个排成一次性闹钟。
/// 代价是有视野上限：每次打开 App 都会把视野往后续（见 [ReminderService.syncAll]）。
const int courseReminderHorizonWeeks = 8;

/// 每门课预分配的提醒槽位数。
///
/// 一周最多一节课，所以 8 周视野最多 8 次；槽位数固定，重排时才知道
/// 「这次只排了 3 次，第 3~7 号槽位的旧闹钟要撤掉」。
const int maxCourseReminderSlots = courseReminderHorizonWeeks;

/// 课程提醒的通知 id。
///
/// 每门课占 [courseReminderId] 开头的连续 100 个槽位，与事件（100000+）、
/// 任务（200000+）的号段互不重叠。100 远大于 [maxCourseReminderSlots]，
/// 以后把视野放宽到 100 周都不用改号段规则。
int courseReminderId(int courseId, int slot) => 300000 + courseId * 100 + slot;

class CourseReminder {
  const CourseReminder({
    required this.id,
    required this.fireAt,
    required this.title,
    required this.body,
  });

  /// 通知 id（已含槽位，可直接下发）。
  final int id;

  /// 该响的时刻（= 上课时刻 - 提前量）。
  final DateTime fireAt;
  final String title;
  final String body;
}

/// 课程通知正文：带上地点，省得再点开 App 查教室。
String courseReminderBody(Course course, int leadMinutes) {
  final base = reminderBody(course.title, leadMinutes);
  final place = course.location?.trim();
  if (place == null || place.isEmpty) return base;
  return '$base（$place）';
}

/// 把一门课的周期规则展开成具体提醒时刻。
///
/// 展开范围是「从今天起 [horizonWeeks] 周」与「学期区间」的交集：
/// - 学期已经结束、或开学时间推后到视野之外 → 空；
/// - 学期还没开始 → 从学期第一天开始算，假期里不排；
/// - 单双周按 [matchesWeekParity] 过滤；
/// - 今天这节课的提醒时刻已经过去 → 排下一次（不能立刻补一条）。
///
/// 返回的列表按时间升序，第 n 条的 id 固定用第 n 号槽位。
List<CourseReminder> planCourseReminders({
  required Course course,
  required DateTime now,
  int leadMinutes = defaultCourseLeadMinutes,
  int horizonWeeks = courseReminderHorizonWeeks,
}) {
  final courseId = course.id;
  if (courseId == null) return const [];

  final startMinutes = tryParseHm(course.startTime);
  if (startMinutes == null) return const [];

  final semesterStart = DateTime.tryParse(course.semesterStart);
  final semesterEnd = DateTime.tryParse(course.semesterEnd);
  if (semesterStart == null || semesterEnd == null) return const [];

  final first = DateTime(
    semesterStart.year,
    semesterStart.month,
    semesterStart.day,
  );
  final last = DateTime(semesterEnd.year, semesterEnd.month, semesterEnd.day);

  final today = DateTime(now.year, now.month, now.day);
  // 恰好 horizonWeeks 个自然周：本周今天 ~ 未来第 horizonWeeks 周的同一天。
  final scanEnd = today.add(Duration(days: horizonWeeks * 7 - 1));

  final result = <CourseReminder>[];
  for (
    var day = today;
    !day.isAfter(scanEnd) && result.length < maxCourseReminderSlots;
    day = day.add(const Duration(days: 1))
  ) {
    final target = DateTime(day.year, day.month, day.day);
    if (target.isBefore(first)) continue;
    if (target.isAfter(last)) break;
    if (target.weekday != course.dayOfWeek) continue;
    if (!matchesWeekParity(course, target)) continue;

    final startAt = DateTime(
      target.year,
      target.month,
      target.day,
      startMinutes ~/ 60,
      startMinutes % 60,
    );
    final fireAt = startAt.subtract(
      Duration(minutes: leadMinutes <= 0 ? 0 : leadMinutes),
    );
    // 今天这节课的提醒点已经过去：跳过，等下一周。
    if (!fireAt.isAfter(now)) continue;

    result.add(
      CourseReminder(
        id: courseReminderId(courseId, result.length),
        fireAt: fireAt,
        title: course.title,
        body: courseReminderBody(
          course,
          actualLeadMinutes(startAt, fireAt),
        ),
      ),
    );
  }
  return result;
}
