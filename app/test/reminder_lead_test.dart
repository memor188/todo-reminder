import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/models/event_item.dart';
import 'package:todo_app/models/task.dart';
import 'package:todo_app/models/timeline.dart';
import 'package:todo_app/services/backup_codec.dart';

/// V3 提前量：时刻计算、文案、以及老数据/老备份的向后兼容。
void main() {
  final now = DateTime(2026, 11, 22, 14, 30);

  group('resolveRemindAt', () {
    test('事件本身已过 → 不提醒', () {
      expect(
        resolveRemindAt(
          eventTime: DateTime(2026, 11, 22, 14),
          leadMinutes: 0,
          now: now,
        ),
        isNull,
      );
    });

    test('到点提醒原样返回事件时刻', () {
      final at = DateTime(2026, 11, 22, 15);
      expect(resolveRemindAt(eventTime: at, leadMinutes: 0, now: now), at);
    });

    test('提前 15 分钟 = 事件时刻减 15 分钟', () {
      expect(
        resolveRemindAt(
          eventTime: DateTime(2026, 11, 22, 15),
          leadMinutes: 15,
          now: now,
        ),
        DateTime(2026, 11, 22, 14, 45),
      );
    });

    test('提前量算出来已过去、事件还没到 → 退化为立刻提醒而不是丢掉', () {
      final result = resolveRemindAt(
        eventTime: DateTime(2026, 11, 22, 15),
        leadMinutes: 60,
        now: now,
      );
      expect(result, isNotNull);
      expect(result!.isAfter(now), isTrue);
      // 落在很近的未来，保证下游 schedule() 不会因「时间已过」抛错。
      expect(result.difference(now).inSeconds, lessThanOrEqualTo(10));
    });

    test('提前量不改变「事件已过就不提醒」的判断', () {
      expect(
        resolveRemindAt(
          eventTime: DateTime(2026, 11, 21, 9),
          leadMinutes: 30,
          now: now,
        ),
        isNull,
      );
    });

    test('负数提前量按到点处理，不会把提醒推到事件之后', () {
      final at = DateTime(2026, 11, 22, 15);
      expect(resolveRemindAt(eventTime: at, leadMinutes: -10, now: now), at);
    });
  });

  group('提前量文案', () {
    test('leadLabel 三种形态', () {
      expect(leadLabel(0), '到点提醒');
      expect(leadLabel(15), '提前 15 分钟');
      expect(leadLabel(60), '提前 1 小时');
    });

    test('reminderBody 区分到点与还有多久', () {
      expect(reminderBody('考试', 0), '到点了：考试');
      expect(reminderBody('考试', 15), '还有 15 分钟：考试');
      expect(reminderBody('考试', 60), '还有 1 小时：考试');
    });

    test('档位表包含默认值，且首项是到点', () {
      expect(leadMinuteOptions.first, 0);
      expect(leadMinuteOptions, contains(defaultEventLeadMinutes));
      expect(leadMinuteOptions, contains(defaultTaskLeadMinutes));
    });
  });

  group('模型向后兼容', () {
    test('事件缺 remind_before_minutes 时按 0（到点）', () {
      final item = EventItem.fromMap({
        'id': 1,
        'title': '考试',
        'start_at': '2026-11-23T17:00:00',
        'done': 0,
      });
      expect(item.remindBeforeMinutes, 0);
    });

    test('事件带提前量往返一致', () {
      const item = EventItem(
        id: 3,
        title: '讲座',
        startAt: '2026-11-23T19:00:00',
        remindBeforeMinutes: 30,
      );
      final back = EventItem.fromMap(item.toMap());
      expect(back.remindBeforeMinutes, 30);
      expect(back.title, '讲座');
    });

    test('任务缺 remind_before_minutes 时按 0', () {
      final item = TaskItem.fromMap({
        'id': 2,
        'title': '取快递',
        'due_date': '2026-11-23',
        'done': 0,
      });
      expect(item.remindBeforeMinutes, 0);
    });

    test('任务带提前量往返一致', () {
      const item = TaskItem(
        id: 4,
        title: '交作业',
        dueDate: '2026-11-24',
        dueTime: '23:00',
        remindBeforeMinutes: 60,
      );
      final back = TaskItem.fromMap(item.toMap());
      expect(back.remindBeforeMinutes, 60);
      expect(back.dueTime, '23:00');
    });
  });

  group('老备份仍可导入', () {
    test('v1 备份里没有提前量字段 → 导入为 0，不报错', () {
      final data = decodeBackup(
        '{"schema_version":1,"courses":[],'
        '"events":[{"title":"考试","start_at":"2026-11-23T17:00:00","done":0}],'
        '"tasks":[{"title":"取快递","due_date":"2026-11-23","done":0}]}',
      );
      expect(data.events.single.remindBeforeMinutes, 0);
      expect(data.tasks.single.remindBeforeMinutes, 0);
    });

    test('带提前量的备份往返后保留原值', () {
      final source = encodeBackup(
        const BackupData(
          courses: [],
          events: [
            EventItem(
              title: '考试',
              startAt: '2026-11-23T17:00:00',
              remindBeforeMinutes: 30,
            ),
          ],
          tasks: [],
        ),
      );
      expect(decodeBackup(source).events.single.remindBeforeMinutes, 30);
    });
  });
}
