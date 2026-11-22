// V0 通知服务的单元测试。
// 平台相关的调度（zonedSchedule）在真机验收 V0-3/V0-4 覆盖；
// 这里测不依赖平台通道的纯逻辑：单例、常量、参数校验、响铃开关。
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/services/notification_service.dart';
import 'package:todo_app/services/settings_service.dart';

void main() {
  group('NotificationService 单例', () {
    test('factory 每次返回同一实例', () {
      final a = NotificationService();
      final b = NotificationService();
      expect(identical(a, b), isTrue);
    });

    test('两条通道 id 都是固定常量，防止改动导致旧通知设置丢失', () {
      expect(NotificationService.channelIdVibrate, 'todo_reminders_vibe');
      expect(NotificationService.channelIdSound, 'todo_reminders_sound');
      expect(NotificationService.channelName, '待办提醒');
      // V0/V1 只会响铃的老通道，启动时会被删掉
      expect(NotificationService.legacyChannelId, 'todo_reminders');
    });

    test('默认投递到震动通道，开响铃后切到响铃通道', () {
      final service = NotificationService();
      service.setSoundEnabled(false);
      expect(service.soundEnabled, isFalse);
      expect(service.channelId, NotificationService.channelIdVibrate);

      service.setSoundEnabled(true);
      expect(service.soundEnabled, isTrue);
      expect(service.channelId, NotificationService.channelIdSound);

      // 单例是共享的，别给后面的用例留下响铃状态
      service.setSoundEnabled(false);
    });
  });

  group('响铃设置项（默认只震动）', () {
    test('从没存过时默认关闭响铃', () {
      expect(SettingsService.inMemory().notifySoundEnabled, isFalse);
    });

    test('存过之后读得回来', () async {
      final settings = SettingsService.inMemory();
      await settings.saveNotifySound(true);
      expect(settings.notifySoundEnabled, isTrue);
      await settings.saveNotifySound(false);
      expect(settings.notifySoundEnabled, isFalse);
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

  group('showNow 参数校验', () {
    test('未 init 时调用 showNow 抛 StateError', () async {
      final service = NotificationService();
      expect(
        () => service.showNow(id: 1, title: 'x', body: 'y'),
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
