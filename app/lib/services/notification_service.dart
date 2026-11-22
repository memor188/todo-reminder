import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// timezone 0.11.x：initializeTimeZones 在 data/latest.dart，不在 timezone.dart
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'reminder_sink.dart';

/// V0 通知服务（单例）。
///
/// 封装四件事：初始化、申请权限、定时调度、即时测试通知。
/// 注意 FLN 23.x 的 API 与旧教程不同：
/// - initialize 用命名参数 settings:
/// - zonedSchedule 必填 androidScheduleMode:
class NotificationService implements ReminderSink {
  NotificationService._internal();

  static final NotificationService instance = NotificationService._internal();

  factory NotificationService() => instance;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// 两个通道：**默认震动**，响铃可选（2026-11-22 用户要求）。
  ///
  /// 为什么必须是两个 id 而不是一个 id 改配置：Android 8+ 的响铃/震动是
  /// **channel 属性**，通道一旦建好就不能改（`createNotificationChannel`
  /// 对已存在的 id 只更新名称和描述，声音字段会被系统忽略）。想让用户随时
  /// 开关响铃，只能预先建两条通道，调度时按用户选择投递到其中一条。
  ///
  /// 老通道 `todo_reminders`（会响铃）因此弃用——见 [legacyChannelId]。
  static const String channelIdVibrate = 'todo_reminders_vibe';
  static const String channelIdSound = 'todo_reminders_sound';

  /// V0/V1 建的旧通道，只有响铃没有开关。启动时删掉，免得系统设置里留一条
  /// 名不副实的「待办提醒」。
  static const String legacyChannelId = 'todo_reminders';

  static const String channelName = '待办提醒';
  static const String channelDescription = '到点提醒事项';

  /// 当前是否响铃。默认 false，由 [SettingsService.notifySoundEnabled] 注入。
  bool _soundEnabled = false;

  bool get soundEnabled => _soundEnabled;

  /// 切换响铃。**只改投递走哪条通道**，已排好的通知不会自动搬过去，
  /// 调用方必须跟着做一次整体重排（`ReminderService.syncAll`）。
  void setSoundEnabled(bool value) => _soundEnabled = value;

  String get channelId => _soundEnabled ? channelIdSound : channelIdVibrate;

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

    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();

    // 必须显式创建 channel：Android 16 上 alarm 触发时 receiver 在独立
    // 进程里发通知，若 channel 不存在会被系统静默丢弃（真机实测踩坑）。
    const vibrate = AndroidNotificationChannel(
      channelIdVibrate,
      '$channelName（震动）',
      description: '到点震动提醒，不出声',
      importance: Importance.max,
      playSound: false,
      enableVibration: true,
    );
    const sound = AndroidNotificationChannel(
      channelIdSound,
      '$channelName（响铃 + 震动）',
      description: '到点响铃并震动',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );
    await android?.createNotificationChannel(vibrate);
    await android?.createNotificationChannel(sound);

    // 删旧通道会连带丢掉排在它上面的通知，所以这一句之后
    // `_AppState._syncReminders()` 必须跑成功（它在启动时无条件跑一次，
    // 排的 id 与这里无关，只是换通道重投）。
    try {
      await android?.deleteNotificationChannel(channelId: legacyChannelId);
    } catch (_) {
      // 通道本来就不存在（全新安装）也会走到这里，不算错误。
    }

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

  NotificationDetails get _notificationDetails => NotificationDetails(
    android: AndroidNotificationDetails(
      channelId,
      _soundEnabled ? '$channelName（响铃 + 震动）' : '$channelName（震动）',
      channelDescription: channelDescription,
      importance: Importance.max,
      priority: Priority.max,
      // 8.0 以下没有通道，靠这两个开关起作用；8.0 以上以通道为准，
      // 这里写成和通道一致，免得两处说法打架。
      playSound: _soundEnabled,
      enableVibration: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      // 按"闹钟"归类：锁屏 heads-up + 不受静音影响（vivo 实测锁屏默认隐藏
      // PRIVATE 内容，设 public 才看得到标题）。
      category: AndroidNotificationCategory.alarm,
      visibility: NotificationVisibility.public,
    ),
  );

  /// 在指定绝对时间调度一条通知。
  @override
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

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);
  Future<void> cancelAll() => _plugin.cancelAll();
}
