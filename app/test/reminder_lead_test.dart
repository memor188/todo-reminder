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

  group('正文按实际剩余时间算，不按配置值', () {
    test('正常提前时，实际剩余等于配置的提前量', () {
      final event = DateTime(2026, 11, 22, 15);
      final fire = resolveRemindAt(
        eventTime: event,
        leadMinutes: 15,
        now: now,
      )!;
      expect(actualLeadMinutes(event, fire), 15);
      expect(reminderBody('考试', actualLeadMinutes(event, fire)), '还有 15 分钟：考试');
    });

    test('退化成立刻提醒时，正文报真实剩余而不是配置的 5 分钟', () {
      // 14:58 建「15:00 事件，提前 5 分钟」：减完是 14:53 已过 → 立刻提醒。
      // 实际只剩 2 分钟，这时候写「还有 5 分钟」就是在骗人。
      final buggyNow = DateTime(2026, 11, 22, 14, 58);
      final event = DateTime(2026, 11, 22, 15);
      final fire = resolveRemindAt(
        eventTime: event,
        leadMinutes: 5,
        now: buggyNow,
      )!;

      final actual = actualLeadMinutes(event, fire);
      expect(actual, 2);
      expect(actual, lessThan(5));
      expect(reminderBody('考试', actual), '还有 2 分钟：考试');
    });

    test('到点提醒剩余为 0，正文是「到点了」', () {
      final event = DateTime(2026, 11, 22, 15);
      final fire = resolveRemindAt(eventTime: event, leadMinutes: 0, now: now)!;
      expect(actualLeadMinutes(event, fire), 0);
      expect(reminderBody('考试', 0), '到点了：考试');
    });

    test('剩余不足半分钟按 0 处理，不会报出「还有 0 分钟」', () {
      final event = DateTime(2026, 11, 22, 14, 31);
      final fire = event.subtract(const Duration(seconds: 20));
      final actual = actualLeadMinutes(event, fire);
      expect(actual, 0);
      expect(reminderBody('考试', actual), '到点了：考试');
    });

    test('提醒晚于事件（异常输入）不会算出负数', () {
      final event = DateTime(2026, 11, 22, 15);
      final fire = event.add(const Duration(minutes: 5));
      expect(actualLeadMinutes(event, fire), 0);
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
