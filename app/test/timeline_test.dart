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

  group('任务提醒时间', () {
    test('有钟点按钟点提醒', () {
      final at = resolveTaskReminderAt(DateTime(2026, 11, 27), '17:30');
      expect(at, DateTime(2026, 11, 27, 17, 30));
    });

    test('无钟点默认当天 09:00 提醒（不是不提醒）', () {
      final at = resolveTaskReminderAt(DateTime(2026, 11, 27), null);
      expect(at, DateTime(2026, 11, 27, 9, 0));
      expect(
        resolveTaskReminderAt(DateTime(2026, 11, 27), '  '),
        DateTime(2026, 11, 27, 9, 0),
      );
    });

    test('钟点文本非法返回 null，不猜时间', () {
      expect(resolveTaskReminderAt(DateTime(2026, 11, 27), '下午五点'), isNull);
    });
  });

  group('课表网格布局', () {
    TimelineEntry entry(String key, EntryType type, int start, {int? end}) =>
        TimelineEntry(
          key: key,
          sourceId: 1,
          type: type,
          title: key,
          sortMinutes: start,
          endMinutes: end,
          timeLabel: '',
        );

    test('课程按真实起止铺开（08:00-09:40）', () {
      final slots = layoutDay([entry('c', EntryType.course, 480, end: 580)]);
      expect(slots.single.startMinutes, 480);
      expect(slots.single.endMinutes, 580);
      expect(slots.single.columns, 1);
    });

    test('无结束时间的条目默认撑开 1 小时', () {
      final slots = layoutDay([entry('e', EntryType.event, 600)]);
      expect(slots.single.endMinutes, 660);
    });

    test('时间重叠的条目并排平分宽度', () {
      final slots = layoutDay([
        entry('a', EntryType.course, 480, end: 540),
        entry('b', EntryType.event, 500, end: 560),
      ]);
      expect(slots.every((s) => s.columns == 2), isTrue);
      expect(slots.map((s) => s.column).toSet(), {0, 1});
    });

    test('不重叠的条目各占整列', () {
      final slots = layoutDay([
        entry('a', EntryType.course, 480, end: 540),
        entry('b', EntryType.event, 600, end: 660),
      ]);
      expect(slots.every((s) => s.columns == 1), isTrue);
    });

    test('结束早于开始的脏数据按默认 1 小时处理', () {
      final slots = layoutDay([
        entry('a', EntryType.event, 480, end: 470),
      ]);
      expect(slots.single.endMinutes, 540);
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

    test('单双周按「学期起始那一周的周一」起算', () {
      // 学期 2026-11-01（周日）开始 → 第 1 周 = 10-26（周一）~ 11-01（周日）。
      // 于是 11-16 是第 4 周（偶）、11-23 是第 5 周（奇）。
      // 这样算而不是从学期首日直接数天数，是为了让「第 N 周」跟课表上的
      // 周次写法（如 3-18 周）落在同一个周块里——两套算法会在非周一起始的
      // 学期里错开一周。
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
      expect(expandCourse(odd, DateTime(2026, 11, 23)).length, 1);
      expect(expandCourse(even, DateTime(2026, 11, 23)), isEmpty);
      expect(expandCourse(odd, DateTime(2026, 11, 16)), isEmpty);
      expect(expandCourse(even, DateTime(2026, 11, 16)).length, 1);
    });
  });

  group('三类条目混排', () {
    test('事件、任务、课程合并后按时间排序，任务无时间放最后', () {
      final day = DateTime(2026, 11, 23);
      final entries = buildTimeline(
        day: day,
        courses: [mondayCourse()],
        events: [const EventItem(title: '考试', startAt: '2026-11-23T17:00:00')],
        tasks: [const TaskItem(title: '取快递', dueDate: '2026-11-23')],
      );

      expect(entries.map((e) => e.title).toList(), ['高数', '考试', '取快递']);
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
