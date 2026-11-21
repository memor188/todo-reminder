// V0 通知服务的单元测试。
// 平台相关的调度（zonedSchedule）在真机验收 V0-3/V0-4 覆盖；
// 这里测不依赖平台通道的纯逻辑：单例、常量、参数校验、时间推算。
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/services/notification_service.dart';

void main() {
  group('NotificationService 单例', () {
    test('factory 每次返回同一实例', () {
      final a = NotificationService();
      final b = NotificationService();
      expect(identical(a, b), isTrue);
    });

    test('channel id 是固定常量，防止改动导致旧通知设置丢失', () {
      expect(NotificationService.channelId, 'todo_reminders');
      expect(NotificationService.channelName, '待办提醒');
    });
  });

  group('schedule 参数校验', () {
    test('未 init 时调用 schedule 抛 StateError', () async {
      final service = NotificationService();
      // 注意：若其它测试先 init 过会影响此断言，因此用独立实例语义检查。
      // 单例 _initialized 默认 false（test 环境不跑 main()）。
      expect(
        () => service.schedule(
          id: 1,
          title: 'x',
          body: 'y',
          eventTime: DateTime.now().add(const Duration(seconds: 5)),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('时间推算（对齐 main.dart 的顺延逻辑）', () {
    test('若选定时刻已过，顺延到次日同一时刻', () {
      final now = DateTime.now();
      // 取一个肯定已过的时间：今天 00:00
      var target = DateTime(now.year, now.month, now.day, 0, 0);
      if (!target.isAfter(now)) {
        target = target.add(const Duration(days: 1));
      }
      expect(target.isAfter(now), isTrue);
      expect(target.day, now.day + 1);
    });
  });
}
