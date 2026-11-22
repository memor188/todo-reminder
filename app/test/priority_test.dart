// V3 优先级标签的测试。
//
// 优先级只做视觉标记，不参与排序——日程按时间看，把紧急的条目提到早上八点
// 的课前面会让时间线错乱。所以这里断言的是「字段能存能读、能传到显示层」，
// 以及顺序不变。
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/models/event_item.dart';
import 'package:todo_app/models/task.dart';
import 'package:todo_app/models/timeline.dart';
import 'package:todo_app/services/backup_codec.dart';

void main() {
  group('标签与判定', () {
    test('三档中文名', () {
      expect(priorityLabel(priorityNormal), '普通');
      expect(priorityLabel(priorityImportant), '重要');
      expect(priorityLabel(priorityUrgent), '紧急');
    });

    test('未知值按普通处理，不崩也不显示怪标签', () {
      expect(priorityLabel(99), '普通');
      expect(priorityLabel(-1), '普通');
    });

    test('普通不算重要，重要和紧急都算', () {
      expect(priorityOptions, [0, 1, 2]);
      expect(priorityNormal >= priorityImportant, isFalse);
      expect(priorityImportant >= priorityImportant, isTrue);
      expect(priorityUrgent >= priorityImportant, isTrue);
    });
  });

  group('模型存取', () {
    test('事件读写保留优先级', () {
      const item = EventItem(
        title: '考试',
        startAt: '2026-11-23T17:00:00',
        priority: priorityUrgent,
      );
      expect(EventItem.fromMap(item.toMap()).priority, priorityUrgent);
    });

    test('任务读写保留优先级', () {
      const item = TaskItem(
        title: '交作业',
        dueDate: '2026-11-23',
        priority: priorityImportant,
      );
      expect(TaskItem.fromMap(item.toMap()).priority, priorityImportant);
    });

    test('老数据没有 priority 列 → 按普通处理', () {
      final event = EventItem.fromMap({
        'id': 1,
        'title': '考试',
        'start_at': '2026-11-23T17:00:00',
        'done': 0,
      });
      final task = TaskItem.fromMap({
        'id': 2,
        'title': '交作业',
        'due_date': '2026-11-23',
        'done': 0,
      });
      expect(event.priority, priorityNormal);
      expect(task.priority, priorityNormal);
    });
  });

  group('备份往返', () {
    test('优先级跟着备份走，恢复后还在', () {
      final json = encodeBackup(
        BackupData(
          courses: const [],
          events: const [
            EventItem(
              title: '考试',
              startAt: '2026-11-23T17:00:00',
              priority: priorityUrgent,
            ),
          ],
          tasks: const [
            TaskItem(
              title: '交作业',
              dueDate: '2026-11-23',
              priority: priorityImportant,
            ),
          ],
        ),
      );
      final decoded = decodeBackup(json);
      expect(decoded.events.single.priority, priorityUrgent);
      expect(decoded.tasks.single.priority, priorityImportant);
    });
  });

  group('显示层', () {
    final day = DateTime(2026, 11, 23);

    test('事件和任务的优先级带到时间线条目上', () {
      final entries = buildTimeline(
        day: day,
        courses: const [],
        events: const [
          EventItem(
            id: 1,
            title: '考试',
            startAt: '2026-11-23T17:00:00',
            priority: priorityUrgent,
          ),
        ],
        tasks: const [
          TaskItem(
            id: 2,
            title: '交作业',
            dueDate: '2026-11-23',
            dueTime: '09:00',
            priority: priorityImportant,
          ),
        ],
      );
      expect(entries.first.title, '交作业');
      expect(entries.first.priority, priorityImportant);
      expect(entries.last.priority, priorityUrgent);
    });

    test('优先级不参与排序：还是按时间先后', () {
      final entries = buildTimeline(
        day: day,
        courses: const [],
        events: const [
          EventItem(
            id: 1,
            title: '晚上的紧急事',
            startAt: '2026-11-23T20:00:00',
            priority: priorityUrgent,
          ),
        ],
        tasks: const [
          TaskItem(
            id: 2,
            title: '早上的普通事',
            dueDate: '2026-11-23',
            dueTime: '08:00',
          ),
        ],
      );
      expect(entries.map((e) => e.title), ['早上的普通事', '晚上的紧急事']);
    });

    test('课程没有优先级概念，恒为普通', () {
      final entries = buildTimeline(
        day: day,
        courses: const [],
        events: const [],
        tasks: const [],
      );
      expect(entries, isEmpty);
      const entry = TimelineEntry(
        key: 'k',
        sourceId: 1,
        type: EntryType.course,
        title: '高数',
        sortMinutes: 480,
        timeLabel: '08:00–09:40',
      );
      expect(entry.priority, priorityNormal);
      expect(entry.isImportant, isFalse);
    });
  });
}
