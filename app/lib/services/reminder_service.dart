import 'dart:developer' as developer;

import '../models/course.dart';
import '../models/reminder_plan.dart';
import '../models/timeline.dart';
import 'db_service.dart' show AppData;
import 'reminder_sink.dart';

/// 一次重排的结果，给日志和自检用。
class ReminderSyncResult {
  const ReminderSyncResult({
    this.scheduled = 0,
    this.skipped = 0,
    this.failed = 0,
  });

  /// 成功排上的条数。
  final int scheduled;

  /// 时刻已过 / 已完成 / 排不进视野，主动放弃的条数（不是错误）。
  final int skipped;

  /// 下发时抛异常的条数（权限被撤、系统闹钟满等）。
  final int failed;

  ReminderSyncResult operator +(ReminderSyncResult other) =>
      ReminderSyncResult(
        scheduled: scheduled + other.scheduled,
        skipped: skipped + other.skipped,
        failed: failed + other.failed,
      );

  @override
  String toString() => '排上 $scheduled 条，跳过 $skipped 条，失败 $failed 条';
}

/// 把数据库里的数据翻译成系统闹钟。
///
/// 只在写入时排一次是不够的：从备份恢复、改系统时间、升级安装、系统清理掉
/// 闹钟之后，库里还有数据而闹钟已经没了——用户以为提醒在，其实不会响。
/// 所以除了「保存时排」，还要有「整体重排」这个兜底动作，在启动和数据
/// 变更之后跑一遍。重排是幂等的：用的 id 和保存时完全相同，重复排只是覆盖。
class ReminderService {
  const ReminderService(this.sink);

  final ReminderSink sink;

  /// 事件与任务的通知 id 号段（课程在 [courseReminderId] 里另开一段）。
  static const int eventIdBase = 100000;
  static const int taskIdBase = 200000;

  static int eventNotificationId(int id) => eventIdBase + id;
  static int taskNotificationId(int id) => taskIdBase + id;

  /// 按库里现有数据把所有提醒重排一遍。
  Future<ReminderSyncResult> syncAll(AppData data, {DateTime? now}) async {
    final moment = now ?? DateTime.now();
    var result = const ReminderSyncResult();

    for (final event in data.events) {
      final id = event.id;
      if (id == null) continue;
      final startAt = DateTime.tryParse(event.startAt);
      final at = startAt == null || event.done
          ? null
          : plannedRemindAt(
              eventTime: startAt,
              leadMinutes: event.remindBeforeMinutes,
              now: moment,
            );
      result += await _apply(
        id: eventNotificationId(id),
        at: at,
        title: event.title,
        body: at == null
            ? ''
            : reminderBody(
                event.title,
                actualLeadMinutes(startAt!, at),
              ),
      );
    }

    for (final task in data.tasks) {
      final id = task.id;
      if (id == null) continue;
      final date = DateTime.tryParse(task.dueDate);
      // 无钟点任务也在当天 09:00 提醒，和手动录入页的口径一致。
      final dueAt = date == null || task.done
          ? null
          : resolveTaskReminderAt(date, task.dueTime);
      final at = dueAt == null
          ? null
          : plannedRemindAt(
              eventTime: dueAt,
              leadMinutes: task.remindBeforeMinutes,
              now: moment,
            );
      result += await _apply(
        id: taskNotificationId(id),
        at: at,
        title: task.title,
        body: at == null ? '' : reminderBody(task.title, actualLeadMinutes(dueAt!, at)),
      );
    }

    for (final course in data.courses) {
      result += await syncCourse(course, now: moment);
    }
    return result;
  }

  /// 单独重排一门课的提醒（保存课程后立刻调用，不必整体重排）。
  Future<ReminderSyncResult> syncCourse(Course course, {DateTime? now}) async {
    final courseId = course.id;
    if (courseId == null) return const ReminderSyncResult();

    final reminders = planCourseReminders(
      course: course,
      now: now ?? DateTime.now(),
    );
    var result = const ReminderSyncResult();

    // 这次只排了 n 条，第 n 号以后的槽位是上一次留下的，必须撤掉，
    // 否则「课程改了上课时间」之后旧时间的闹钟照样会响。
    for (var slot = reminders.length; slot < maxCourseReminderSlots; slot++) {
      try {
        await sink.cancel(courseReminderId(courseId, slot));
      } catch (error) {
        developer.log('撤课程提醒失败: $error', name: 'ReminderService');
      }
    }
    for (final reminder in reminders) {
      result += await _apply(
        id: reminder.id,
        at: reminder.fireAt,
        title: reminder.title,
        body: reminder.body,
      );
    }
    return result;
  }

  /// 整个删掉一门课时，把所有槽位撤干净（不知道上次排了几条，全撤省心）。
  Future<void> cancelCourse(int courseId) async {
    for (var slot = 0; slot < maxCourseReminderSlots; slot++) {
      try {
        await sink.cancel(courseReminderId(courseId, slot));
      } catch (error) {
        developer.log('撤课程提醒失败: $error', name: 'ReminderService');
      }
    }
  }

  /// 单条下发。时刻为 null 表示「不该响」，顺手把旧闹钟撤掉。
  ///
  /// 单条失败不往外抛：一条排不上不该拖垮整轮重排。
  Future<ReminderSyncResult> _apply({
    required int id,
    required DateTime? at,
    required String title,
    required String body,
  }) async {
    try {
      if (at == null) {
        await sink.cancel(id);
        return const ReminderSyncResult(skipped: 1);
      }
      await sink.schedule(id: id, title: title, body: body, eventTime: at);
      return const ReminderSyncResult(scheduled: 1);
    } catch (error) {
      developer.log('排提醒失败 id=$id: $error', name: 'ReminderService');
      return const ReminderSyncResult(failed: 1);
    }
  }
}
