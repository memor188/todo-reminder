import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/models/course.dart';
import 'package:todo_app/models/event_item.dart';
import 'package:todo_app/models/task.dart';
import 'package:todo_app/models/timeline.dart';

void main() {
  Course mondayCourse() => Course(
        title: '高数',
        dayOfWeek: 1,
        startTime: '08:00',
        endTime: '09:40',
        location: 'E104',
        semesterStart: '2026-11-01',
        semesterEnd: '2027-01-31',
      );

  group('时间文本归一化', () {
    test('中文输入法的全角冒号与全角数字可解析', () {
      expect(normalizeTimeText('17：00'), '17:00');
      expect(normalizeTimeText('１７；３０'), '17:30');
      expect(tryParseHm('17：00'), 17 * 60);
      expect(tryParseHm('bad'), isNull);
    });

    test('中文输入法的全角连日期可解析', () {
      expect(normalizeDateText('２０２６－１１－０１'), '2026-11-01');
      expect(normalizeDateText('2026—11—01'), '2026-11-01');
      expect(DateTime.tryParse(normalizeDateText('２０２６－１１－０１')), isNotNull);
    });
  });

  group('课程展开', () {
    test('只在学期范围内、匹配星期的日期展开', () {
      final course = mondayCourse();
      final monday = DateTime(2026, 11, 23); // 周一
      final tuesday = DateTime(2026, 11, 24);
      final outside = DateTime(2026, 2, 2);

      expect(expandCourse(course, monday).length, 1);
      expect(expandCourse(course, tuesday), isEmpty);
      expect(expandCourse(course, outside), isEmpty);
      expect(expandCourse(course, monday).single.timeLabel, '08:00–09:40');
    });

    test('单双周规则按学期周数过滤', () {
      final odd = Course(
        title: '高数',
        dayOfWeek: 1,
        startTime: '08:00',
        endTime: '09:40',
        semesterStart: '2026-11-01',
        semesterEnd: '2027-01-31',
        weekParity: 1,
      );
      final even = Course(
        title: '电路',
        dayOfWeek: 1,
        startTime: '10:00',
        endTime: '11:30',
        semesterStart: '2026-11-01',
        semesterEnd: '2027-01-31',
        weekParity: 2,
      );
      // 11-23 是第 4 周（偶），11-16 是第 3 周（奇）
      expect(expandCourse(odd, DateTime(2026, 11, 23)), isEmpty);
      expect(expandCourse(even, DateTime(2026, 11, 23)).length, 1);
      expect(expandCourse(odd, DateTime(2026, 11, 16)).length, 1);
    });
  });

  group('三类条目混排', () {
    test('事件、任务、课程合并后按时间排序，任务无时间放最后', () {
      final day = DateTime(2026, 11, 23);
      final entries = buildTimeline(
        day: day,
        courses: [mondayCourse()],
        events: [
          const EventItem(title: '考试', startAt: '2026-11-23T17:00:00'),
        ],
        tasks: [
          const TaskItem(title: '取快递', dueDate: '2026-11-23'),
        ],
      );

      expect(entries.map((e) => e.title).toList(),
          ['高数', '考试', '取快递']);
      expect(entries.last.sortMinutes, 24 * 60);
    });

    test('已完成的任务不出现在时间线，includeDone=true 才出现', () {
      final day = DateTime(2026, 11, 23);
      final tasks = [
        const TaskItem(title: '已完成', dueDate: '2026-11-23', done: true),
      ];
      expect(
        buildTimeline(day: day, courses: [], events: [], tasks: tasks),
        isEmpty,
      );
      expect(
        buildTimeline(
          day: day,
          courses: [],
          events: [],
          tasks: tasks,
          includeDone: true,
        ).length,
        1,
      );
    });
  });
}
