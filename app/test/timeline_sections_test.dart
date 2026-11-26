import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/models/course.dart';
import 'package:todo_app/models/event_item.dart';
import 'package:todo_app/models/task.dart';
import 'package:todo_app/models/timeline.dart';

/// 日程页三态分区（2026-11-25 定稿，见 docs/设计-日程过期分区.md）。
///
/// 这组测试盯的是四个最容易写错的地方：
/// 1. 课程按**下课**判完成（下课=上完了，不是欠账），不是按上课；
/// 2. 无钟点任务压到当天 23:59，不是 24:00；
/// 3. 已完成优先于时间判定；
/// 4. 区内排序是「时间正序 → 优先级高在前 → key」。
void main() {
  // 2026-11-25 是周三。
  final day = DateTime(2026, 11, 25);

  Course wednesdayCourse({String start = '08:00', String end = '09:40'}) =>
      Course(
        id: 1,
        title: '高等数学',
        dayOfWeek: 3,
        startTime: start,
        endTime: end,
        semesterStart: '2026-09-07',
        semesterEnd: '2027-01-17',
      );

  EventItem event({int id = 1, String at = '2026-11-25T14:00:00'}) =>
      EventItem(id: id, title: '讲座', startAt: at);

  TaskItem task({
    int id = 1,
    String? dueTime,
    bool done = false,
    int priority = priorityNormal,
  }) => TaskItem(
    id: id,
    title: '作业$id',
    dueDate: '2026-11-25',
    dueTime: dueTime,
    done: done,
    priority: priority,
  );

  group('resolveEntryState 时间判定', () {
    test('课程上课中不算完成（判定看下课时刻）', () {
      final sections = buildDaySections(
        day: day,
        courses: [wednesdayCourse()],
        events: const [],
        tasks: const [],
        now: DateTime(2026, 11, 25, 9, 0),
      );
      expect(sections.normal, hasLength(1));
      expect(sections.overdue, isEmpty);
    });

    test('课程下课之后算完成，不进已过期（2026-11-26 用户纠正）', () {
      final sections = buildDaySections(
        day: day,
        courses: [wednesdayCourse()],
        events: const [],
        tasks: const [],
        now: DateTime(2026, 11, 25, 10, 0),
      );
      expect(sections.normal, isEmpty);
      expect(sections.overdue, isEmpty, reason: '课是上完的事，不是欠着的');
      expect(sections.done, hasLength(1));
    });

    test('过去的课程也算完成，不堆积在已过期区', () {
      // 翻周看历史时，那天的课早就上完了，不该显示成一堆"欠账"。
      final sections = buildDaySections(
        day: DateTime(2026, 11, 18), // 也是周三，同一门课会排进来
        courses: [wednesdayCourse()],
        events: const [],
        tasks: const [],
        now: DateTime(2026, 11, 25, 10, 0),
      );
      expect(sections.overdue, isEmpty);
      expect(sections.done, hasLength(1));
    });

    test('下课那一分钟仍算上课中（严格大于才过期）', () {
      final sections = buildDaySections(
        day: day,
        courses: [wednesdayCourse()],
        events: const [],
        tasks: const [],
        now: DateTime(2026, 11, 25, 9, 40),
      );
      expect(sections.normal, hasLength(1));
    });

    test('事件过了开始时刻就算过期', () {
      final sections = buildDaySections(
        day: day,
        courses: const [],
        events: [event(at: '2026-11-25T14:00:00')],
        tasks: const [],
        now: DateTime(2026, 11, 25, 15, 0),
      );
      expect(sections.overdue, hasLength(1));
    });

    test('无钟点任务压到 23:59，不是 24:00', () {
      final sections = buildDaySections(
        day: day,
        courses: const [],
        events: const [],
        tasks: [task()],
        now: DateTime(2026, 11, 25, 23, 58),
      );
      // 23:58 < 23:59，还在"今天之内"。
      expect(sections.normal, hasLength(1));

      final after = buildDaySections(
        day: day,
        courses: const [],
        events: const [],
        tasks: [task()],
        now: DateTime(2026, 11, 26, 0, 10),
      );
      expect(after.overdue, hasLength(1));
    });

    test('未来的日期恒为正常，哪怕时刻早于现在', () {
      final tomorrow = DateTime(2026, 11, 26);
      final sections = buildDaySections(
        day: tomorrow,
        courses: const [],
        events: [EventItem(id: 2, title: '早会', startAt: '2026-11-26T08:00:00')],
        tasks: const [],
        now: DateTime(2026, 11, 25, 23, 0),
      );
      expect(sections.normal, hasLength(1));
      expect(sections.overdue, isEmpty);
    });

    test('已完成优先于时间判定：勾了就是完成，不管过没过', () {
      final sections = buildDaySections(
        day: day,
        courses: const [],
        events: const [],
        tasks: [task(done: true)],
        now: DateTime(2026, 11, 25, 8, 0),
      );
      expect(sections.done, hasLength(1));
      expect(sections.normal, isEmpty);
    });

    test('取消勾选后按当前时间重判：未超时回正常，已超时回过期', () {
      final entry = buildTimeline(
        day: day,
        courses: const [],
        events: const [],
        tasks: [task(dueTime: '14:00')],
        includeDone: true,
      ).single;

      expect(
        resolveEntryState(entry, day: day, now: DateTime(2026, 11, 25, 13, 0)),
        EntryState.normal,
      );
      expect(
        resolveEntryState(entry, day: day, now: DateTime(2026, 11, 25, 15, 0)),
        EntryState.overdue,
      );
    });
  });

  group('分区与排序', () {
    test('三区互不交错，各归各位', () {
      final sections = buildDaySections(
        day: day,
        courses: [wednesdayCourse()],
        events: [event(at: '2026-11-25T14:00:00')],
        tasks: [task(id: 1, dueTime: '20:00'), task(id: 2, done: true)],
        now: DateTime(2026, 11, 25, 15, 0),
      );
      // 晚上 8 点的任务还没到 → 正常；上午的课已下课 → 完成（课不是欠账）；
      // 14:00 的讲座已过 → 过期；已完成的那条 → 完成区。
      expect(sections.normal.map((e) => e.key), ['task_1']);
      expect(sections.overdue.map((e) => e.key), ['event_1']);
      expect(sections.done.map((e) => e.key), [
        'course_1_2026-11-25',
        'task_2',
      ]);
    });

    test('区内按时间正序，早的在上', () {
      final sections = buildDaySections(
        day: day,
        courses: const [],
        events: const [],
        tasks: [
          task(id: 1, dueTime: '20:00'),
          task(id: 2, dueTime: '09:00'),
          task(id: 3, dueTime: '14:00'),
        ],
        now: DateTime(2026, 11, 25, 8, 0),
      );
      expect(sections.normal.map((e) => e.key), ['task_2', 'task_3', 'task_1']);
    });

    test('同一时刻按优先级降序，紧急在前', () {
      final sections = buildDaySections(
        day: day,
        courses: const [],
        events: const [],
        tasks: [
          task(id: 1, dueTime: '09:00', priority: priorityNormal),
          task(id: 2, dueTime: '09:00', priority: priorityUrgent),
          task(id: 3, dueTime: '09:00', priority: priorityImportant),
        ],
        now: DateTime(2026, 11, 25, 8, 0),
      );
      expect(sections.normal.map((e) => e.key), ['task_2', 'task_3', 'task_1']);
    });

    test('空日程三段都空', () {
      final sections = buildDaySections(
        day: day,
        courses: const [],
        events: const [],
        tasks: const [],
        now: DateTime(2026, 11, 25, 12, 0),
      );
      expect(sections.isEmpty, isTrue);
      expect(sections.total, 0);
    });
  });
}
