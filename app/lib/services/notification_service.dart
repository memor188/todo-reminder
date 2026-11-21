import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// timezone 0.11.x：initializeTimeZones 在 data/latest.dart，不在 timezone.dart
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// V0 通知服务（单例）。
///
/// 封装四件事：初始化、申请权限、定时调度、即时测试通知。
/// 注意 FLN 23.x 的 API 与旧教程不同：
/// - initialize 用命名参数 settings:
/// - zonedSchedule 必填 androidScheduleMode:
class NotificationService {
  NotificationService._internal();

  static final NotificationService instance = NotificationService._internal();

  factory NotificationService() => instance;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// channel id 定为常量，以后不许改——改了旧通知的设置全丢。
  static const String channelId = 'todo_reminders';
  static const String channelName = '待办提醒';
  static const String channelDescription = '到点提醒事项';

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    // 时区初始化必须在调度之前
    tzdata.initializeTimeZones();

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initializationSettings = InitializationSettings(
      android: androidSettings,
    );

    await _plugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (response) {
        // V0：点击通知暂无跳转逻辑，V1 接入列表页。
      },
    );

    // 必须显式创建 channel：Android 16 上 alarm 触发时 receiver 在独立
    // 进程里发通知，若 channel 不存在会被系统静默丢弃（真机实测踩坑）。
    const channel = AndroidNotificationChannel(
      channelId,
      channelName,
      description: channelDescription,
      importance: Importance.high,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);

    _initialized = true;
  }

  /// Android 13+ 通知权限 + Android 12+ 精确闹钟权限。
  /// 返回通知权限是否被授予，供 UI 给出提示（不静默失败）。
  Future<bool> requestPermissions() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return false;

    final granted = await android.requestNotificationsPermission() ?? false;
    await android.requestExactAlarmsPermission();
    return granted;
  }

  /// 通知权限是否已被授予（V0 验收用）。
  Future<bool> areNotificationsEnabled() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return false;
    return await android.areNotificationsEnabled() ?? false;
  }

  NotificationDetails get _notificationDetails => const NotificationDetails(
    android: AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.high,
      priority: Priority.high,
    ),
  );

  /// 在指定绝对时间调度一条通知。
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime eventTime,
  }) async {
    if (!_initialized) {
      throw StateError('NotificationService.init() must be called first');
    }
    if (eventTime.isBefore(DateTime.now())) {
      throw ArgumentError('eventTime must be in the future');
    }

    // FLN 23.0.3 顶层入口：全命名参数，且已移除
    // uiLocalNotificationDateInterpretation（23 之前旧教程里的参数）。
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(eventTime, tz.local),
      notificationDetails: _notificationDetails,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  /// V0 诊断：绕过闹钟直接发一条通知。
  /// 用来区分「通知投递本身有问题」和「定时触发链路有问题」。
  Future<void> showNow({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_initialized) {
      throw StateError('NotificationService.init() must be called first');
    }
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: _notificationDetails,
    );
  }

  /// 「10 秒后测试」按钮调用：同一套调度代码，只把时间写死。
  Future<void> scheduleTestNotification(String title) {
    return schedule(
      id: 999999,
      title: title,
      body: '这是一条测试提醒',
      eventTime: DateTime.now().add(const Duration(seconds: 10)),
    );
  }

  Future<void> cancel(int id) => _plugin.cancel(id: id);
  Future<void> cancelAll() => _plugin.cancelAll();
}
