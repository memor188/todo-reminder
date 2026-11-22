// ReminderService 的排程决策测试。
//
// 用假的下发通道（ReminderSink）记录「排了哪些、撤了哪些」，就能在不碰
// Android 闹钟的前提下断言整条链路：哪条该响、几点响、正文写什么、
// 哪些旧闹钟该撤掉。
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/models/course.dart';
import 'package:todo_app/models/event_item.dart';
import 'package:todo_app/models/reminder_plan.dart';
import 'package:todo_app/models/task.dart';
import 'package:todo_app/services/db_service.dart' show AppData;
import 'package:todo_app/services/reminder_service.dart';
import 'package:todo_app/services/reminder_sink.dart';

class _Call {
  _Call({
    required this.id,
    required this.title,
    required this.body,
    required this.at,
  });

  final int id;
  final String title;
  final String body;
  final DateTime at;
}

class _RecordingSink implements ReminderSink {
  final List<_Call> scheduled = [];
  final List<int> cancelled = [];

  /// 让指定 id 下发时抛异常，用来测「一条失败不拖垮整轮」。
  final Set<int> failing = {};

  @override
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime eventTime,
  }) async {
    if (failing.contains(id)) throw StateError('模拟下发失败');
    scheduled.add(_Call(id: id, title: title, body: body, at: eventTime));
  }

  @override
  Future<void> cancel(int id) async => cancelled.add(id);
}

final DateTime now = DateTime(2026, 9, 7, 6, 0);

Course course({
  int? id = 2,
  String semesterEnd = '2027-01-15',
  int weekParity = 0,
}) => Course(
  id: id,
  title: '高等数学A',
  dayOfWeek: 1,
  startTime: '08:00',
  endTime: '09:40',
  location: 'E302',
  semesterStart: '2026-09-07',
  semesterEnd: semesterEnd,
  weekParity: weekParity,
);

void main() {
  group('syncAll 排事件', () {
    test('未完成、时刻在未来 → 按提前量排上，正文说还有几分钟', () async {
      final sink = _RecordingSink();
      final result = await ReminderService(sink).syncAll(
        AppData(
          courses: const [],
          events: [
            EventItem(
              id: 1,
              title: '考试',
              startAt: '2026-09-07T15:00:00.000',
              remindBeforeMinutes: 15,
            ),
          ],
          tasks: const [],
        ),
        now: now,
      );

      expect(result.scheduled, 1);
      expect(sink.scheduled.single.id, ReminderService.eventNotificationId(1));
      expect(sink.scheduled.single.at, DateTime(2026, 9, 7, 14, 45));
      expect(sink.scheduled.single.body, '还有 15 分钟：考试');
    });

    test('已经过去了 → 撤掉旧闹钟，不重排', () async {
      final sink = _RecordingSink();
      await ReminderService(sink).syncAll(
        AppData(
          courses: const [],
          events: [
            EventItem(
              id: 1,
              title: '昨天的讲座',
              startAt: '2026-09-06T15:00:00.000',
            ),
          ],
          tasks: const [],
        ),
        now: now,
      );

      expect(sink.scheduled, isEmpty);
      expect(sink.cancelled, [ReminderService.eventNotificationId(1)]);
    });

    test('已完成 → 撤掉旧闹钟', () async {
      final sink = _RecordingSink();
      await ReminderService(sink).syncAll(
        AppData(
          courses: const [],
          events: [
            EventItem(
              id: 1,
              title: '体检',
              startAt: '2026-09-08T09:00:00.000',
              done: true,
            ),
          ],
          tasks: const [],
        ),
        now: now,
      );
      expect(sink.scheduled, isEmpty);
      expect(sink.cancelled, [ReminderService.eventNotificationId(1)]);
    });

    test('提前量已经算不过来的，重排时不能退化成「立刻提醒」', () async {
      // 15:00 的考试、提前 15 分钟 → 该在 14:45 响；现在 14:50，早过了。
      // 保存那一次可以退化成立刻提醒，但每次打开 App 都退化就成了无限重播。
      final sink = _RecordingSink();
      final result = await ReminderService(sink).syncAll(
        AppData(
          courses: const [],
          events: [
            EventItem(
              id: 1,
              title: '考试',
              startAt: '2026-09-07T15:00:00.000',
              remindBeforeMinutes: 15,
            ),
          ],
          tasks: const [],
        ),
        now: DateTime(2026, 9, 7, 14, 50),
      );

      expect(sink.scheduled, isEmpty);
      expect(result.skipped, 1);
    });
  });

  group('syncAll 排任务', () {
    test('有钟点按钟点，提前量 0 时正文说「到点了」', () async {
      final sink = _RecordingSink();
      await ReminderService(sink).syncAll(
        AppData(
          courses: const [],
          events: const [],
          tasks: [
            TaskItem(id: 4, title: '交作业', dueDate: '2026-09-08', dueTime: '14:00'),
          ],
        ),
        now: now,
      );

      expect(sink.scheduled.single.id, ReminderService.taskNotificationId(4));
      expect(sink.scheduled.single.at, DateTime(2026, 9, 8, 14, 0));
      expect(sink.scheduled.single.body, '到点了：交作业');
    });

    test('无钟点任务也在当天 09:00 提醒', () async {
      final sink = _RecordingSink();
      await ReminderService(sink).syncAll(
        AppData(
          courses: const [],
          events: const [],
          tasks: [TaskItem(id: 4, title: '取快递', dueDate: '2026-09-08')],
        ),
        now: now,
      );
      expect(sink.scheduled.single.at, DateTime(2026, 9, 8, 9, 0));
    });

    test('已完成的任务不再响', () async {
      final sink = _RecordingSink();
      await ReminderService(sink).syncAll(
        AppData(
          courses: const [],
          events: const [],
          tasks: [
            TaskItem(
              id: 4,
              title: '交作业',
              dueDate: '2026-09-08',
              dueTime: '14:00',
              done: true,
            ),
          ],
        ),
        now: now,
      );
      expect(sink.scheduled, isEmpty);
      expect(sink.cancelled, [ReminderService.taskNotificationId(4)]);
    });
  });

  group('syncAll 排课程', () {
    test('一门课排满 8 周，正文带地点', () async {
      final sink = _RecordingSink();
      final result = await ReminderService(sink).syncAll(
        AppData(courses: [course()], events: const [], tasks: const []),
        now: now,
      );

      expect(result.scheduled, maxCourseReminderSlots);
      expect(sink.scheduled.first.at, DateTime(2026, 9, 7, 7, 50));
      expect(sink.scheduled.first.body, '还有 10 分钟：高等数学A（E302）');
      expect(
        sink.scheduled.map((c) => c.id),
        List.generate(
          maxCourseReminderSlots,
          (i) => courseReminderId(2, i),
        ),
      );
    });

    test('事件/任务/课程三类同时存在，号段互不覆盖', () async {
      final sink = _RecordingSink();
      await ReminderService(sink).syncAll(
        AppData(
          courses: [course()],
          events: [
            EventItem(id: 1, title: '考试', startAt: '2026-09-07T15:00:00.000'),
          ],
          tasks: [
            TaskItem(id: 1, title: '交作业', dueDate: '2026-09-08', dueTime: '14:00'),
          ],
        ),
        now: now,
      );
      final ids = sink.scheduled.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length, reason: '同一 id 排两次会互相覆盖');
    });
  });

  group('syncCourse 撤掉多余的旧槽位', () {
    test('学期只剩两周 → 排 2 条，撤掉第 2~7 号槽位', () async {
      final sink = _RecordingSink();
      final result = await ReminderService(
        sink,
      ).syncCourse(course(semesterEnd: '2026-09-20'), now: now);

      expect(result.scheduled, 2);
      expect(sink.cancelled, [
        courseReminderId(2, 2),
        courseReminderId(2, 3),
        courseReminderId(2, 4),
        courseReminderId(2, 5),
        courseReminderId(2, 6),
        courseReminderId(2, 7),
      ]);
    });

    test('课程没 id → 什么都不做', () async {
      final sink = _RecordingSink();
      final result = await ReminderService(
        sink,
      ).syncCourse(course(id: null), now: now);
      expect(result.scheduled, 0);
      expect(sink.scheduled, isEmpty);
      expect(sink.cancelled, isEmpty);
    });
  });

  group('cancelCourse', () {
    test('撤掉该课程的全部槽位', () async {
      final sink = _RecordingSink();
      await ReminderService(sink).cancelCourse(2);
      expect(sink.cancelled, [
        for (var i = 0; i < maxCourseReminderSlots; i++) courseReminderId(2, i),
      ]);
    });
  });

  group('一条失败不拖垮整轮', () {
    test('某条下发抛异常时其余照排，失败数如实计入', () async {
      final sink = _RecordingSink()..failing.add(ReminderService.taskNotificationId(4));
      final result = await ReminderService(sink).syncAll(
        AppData(
          courses: const [],
          events: [
            EventItem(id: 1, title: '考试', startAt: '2026-09-07T15:00:00.000'),
          ],
          tasks: [
            TaskItem(id: 4, title: '交作业', dueDate: '2026-09-08', dueTime: '14:00'),
          ],
        ),
        now: now,
      );

      expect(result.failed, 1);
      expect(result.scheduled, 1);
      expect(sink.scheduled.single.id, ReminderService.eventNotificationId(1));
    });
  });
}
