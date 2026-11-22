// V3 课程提醒的排程逻辑测试。
//
// 课程是周期规则，但系统闹钟只能表达「每周同一时刻」，表达不了单双周和
// 学期边界，所以这里把规则展开成一个个具体时刻。这层逻辑全是纯函数，
// 不碰平台通道，可以按任意日期精确断言。
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/models/course.dart';
import 'package:todo_app/models/reminder_plan.dart';

/// 2026-09-07 是周一，当天 06:00。学期 2026-09-07 ~ 2027-01-15，
/// 和 App 里默认的 2026 学期计划一致。
final DateTime mondayEarly = DateTime(2026, 9, 7, 6, 0);

Course course({
  int? id = 1,
  String title = '高等数学A',
  int dayOfWeek = 1,
  String startTime = '08:00',
  String endTime = '09:40',
  String? location = 'E302',
  String semesterStart = '2026-09-07',
  String semesterEnd = '2027-01-15',
  int weekParity = 0,
}) => Course(
  id: id,
  title: title,
  dayOfWeek: dayOfWeek,
  startTime: startTime,
  endTime: endTime,
  location: location,
  semesterStart: semesterStart,
  semesterEnd: semesterEnd,
  weekParity: weekParity,
);

String dayLabel(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

void main() {
  group('窗口基准日自检', () {
    test('2026-09-07 确实是周一（下面的断言都依赖这一点）', () {
      expect(DateTime(2026, 9, 7).weekday, 1);
      expect(DateTime(2026, 11, 22).weekday, 7);
    });
  });

  group('每周同一节课展开', () {
    test('8 周视野排 8 次，每次都是周一上课前 10 分钟', () {
      final reminders = planCourseReminders(
        course: course(),
        now: mondayEarly,
      );
      expect(reminders.length, 8);
      final days = reminders.map((r) => dayLabel(r.fireAt)).toList();
      expect(days, [
        '2026-09-07',
        '2026-09-14',
        '2026-09-21',
        '2026-09-28',
        '2026-10-05',
        '2026-10-12',
        '2026-10-19',
        '2026-10-26',
      ]);
      for (final reminder in reminders) {
        expect(reminder.fireAt.hour, 7);
        expect(reminder.fireAt.minute, 50);
      }
    });

    test('槽位号连续，id 落在课程的号段里', () {
      final reminders = planCourseReminders(course: course(id: 3), now: mondayEarly);
      for (var i = 0; i < reminders.length; i++) {
        expect(reminders[i].id, courseReminderId(3, i));
      }
      // 号段不能和事件（100000+）、任务（200000+）撞，也不能越界到下一门课。
      expect(courseReminderId(1, 0), greaterThan(300000));
      expect(
        courseReminderId(1, maxCourseReminderSlots - 1),
        lessThan(courseReminderId(2, 0)),
      );
    });

    test('正文带地点，省得再点开 App 查教室', () {
      final reminders = planCourseReminders(course: course(), now: mondayEarly);
      expect(reminders.first.title, '高等数学A');
      expect(reminders.first.body, '还有 10 分钟：高等数学A（E302）');
    });

    test('没填地点时正文不带括号', () {
      final reminders = planCourseReminders(
        course: course(location: null),
        now: mondayEarly,
      );
      expect(reminders.first.body, '还有 10 分钟：高等数学A');
    });

    test('提前量 0 表示到点提醒，正文说「到点了」', () {
      final reminders = planCourseReminders(
        course: course(),
        now: mondayEarly,
        leadMinutes: 0,
      );
      expect(reminders.first.fireAt.hour, 8);
      expect(reminders.first.fireAt.minute, 0);
      expect(reminders.first.body, '到点了：高等数学A（E302）');
    });

    test('视野周数可调：4 周就是 4 次', () {
      final reminders = planCourseReminders(
        course: course(),
        now: mondayEarly,
        horizonWeeks: 4,
      );
      expect(reminders.length, 4);
    });
  });

  group('单双周', () {
    test('单周只排第 1、3、5、7 周', () {
      final reminders = planCourseReminders(
        course: course(weekParity: 1),
        now: mondayEarly,
      );
      expect(reminders.map((r) => dayLabel(r.fireAt)), [
        '2026-09-07',
        '2026-09-21',
        '2026-10-05',
        '2026-10-19',
      ]);
    });

    test('双周只排第 2、4、6、8 周', () {
      final reminders = planCourseReminders(
        course: course(weekParity: 2),
        now: mondayEarly,
      );
      expect(reminders.map((r) => dayLabel(r.fireAt)), [
        '2026-09-14',
        '2026-09-28',
        '2026-10-12',
        '2026-10-26',
      ]);
    });

    test('单周课的槽位也是从 0 连续编号', () {
      final reminders = planCourseReminders(
        course: course(weekParity: 1),
        now: mondayEarly,
      );
      for (var i = 0; i < reminders.length; i++) {
        expect(reminders[i].id, courseReminderId(1, i));
      }
    });
  });

  group('学期边界', () {
    test('学期结束后不再排，不会放假了还催上课', () {
      final reminders = planCourseReminders(
        course: course(semesterEnd: '2026-09-20'),
        now: mondayEarly,
      );
      expect(reminders.map((r) => dayLabel(r.fireAt)), [
        '2026-09-07',
        '2026-09-14',
      ]);
    });

    test('学期已完全过去 → 一条都不排', () {
      final reminders = planCourseReminders(
        course: course(
          semesterStart: '2026-02-23',
          semesterEnd: '2026-07-10',
        ),
        now: mondayEarly,
      );
      expect(reminders, isEmpty);
    });

    test('学期还没开学 → 从开学那天开始排，假期里不排', () {
      final reminders = planCourseReminders(
        course: course(semesterStart: '2026-09-14'),
        now: mondayEarly,
      );
      expect(reminders.first.fireAt, DateTime(2026, 9, 14, 7, 50));
      expect(reminders.length, 7); // 09-14 起 7 个周一落在视野内
      expect(
        reminders.every((r) => !r.fireAt.isBefore(DateTime(2026, 9, 14))),
        isTrue,
      );
    });
  });

  group('当天这节课的提醒点已经过了', () {
    test('跳过今天，不立刻补一条，从下周开始', () {
      // 08:00 上课、提前 10 分钟 → 07:50 该响，但现在已经 09:00 了。
      final reminders = planCourseReminders(
        course: course(),
        now: DateTime(2026, 9, 7, 9, 0),
      );
      expect(reminders.length, 7);
      expect(dayLabel(reminders.first.fireAt), '2026-09-14');
    });
  });

  group('坏数据不排', () {
    test('没有 id（还没入库）→ 空', () {
      expect(
        planCourseReminders(course: course(id: null), now: mondayEarly),
        isEmpty,
      );
    });

    test('上课时间非法 → 空', () {
      expect(
        planCourseReminders(course: course(startTime: '早上八点'), now: mondayEarly),
        isEmpty,
      );
    });

    test('学期日期非法 → 空', () {
      expect(
        planCourseReminders(
          course: course(semesterStart: '开学那天'),
          now: mondayEarly,
        ),
        isEmpty,
      );
    });
  });
}
