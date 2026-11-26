import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import 'models/timeline.dart';
import 'screens/ai_chat_screen.dart';
import 'screens/manual_input_screen.dart';
import 'screens/schedule_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/timetable_screen.dart';
import 'services/db_service.dart';
import 'services/notification_service.dart';
import 'services/reminder_service.dart';
import 'services/settings_service.dart';
import 'theme.dart';
import 'widgets/disintegrate/index.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final notifications = NotificationService();
  await notifications.init();
  final granted = await notifications.requestPermissions();

  final db = DbService();
  await db.init();
  final settings = await SettingsService.load();

  // 预编译粉尘消散 shader：编译要几百毫秒，放在启动阶段付掉，
  // 否则第一次勾选时程序还没就绪，会静默降级成普通淡出（效果的开头和
  // 结尾一样，只是没有粉尘）。不支持的设备会抛错，吞掉即可——
  // DisintegrateEffect 自己会降级，不能让它挡住 App 启动。
  try {
    await DisintegrateProgram.preload();
  } catch (_) {}

  // 响铃开关决定投递走哪条通道，必须在启动重排提醒之前注入，
  // 否则首次启动那批闹钟会按默认（只震动）排下去，用户明明开着响铃。
  notifications.setSoundEnabled(settings.notifySoundEnabled);

  runApp(
    App(
      notifications: notifications,
      permissionGranted: granted,
      db: db,
      settings: settings,
    ),
  );
}

class App extends StatefulWidget {
  const App({
    super.key,
    required this.notifications,
    required this.permissionGranted,
    required this.db,
    required this.settings,
  });

  final NotificationService notifications;
  final bool permissionGranted;
  final DbService db;
  final SettingsService settings;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  int _index = 0;
  int _scheduleVersion = 0;
  final _navigatorKey = GlobalKey<NavigatorState>();

  late final ReminderService _reminders = ReminderService(widget.notifications);

  @override
  void initState() {
    super.initState();
    // 启动时把库里的数据重排一遍提醒。
    // 写入时排一次是不够的：从备份恢复、换机重装、系统把闹钟清掉之后，
    // 库里还有数据而闹钟已经没了——用户以为提醒在，其实不会响。
    unawaited(_syncReminders());
  }

  Future<void> _syncReminders() async {
    try {
      final data = await widget.db.queryAll();
      final result = await _reminders.syncAll(data);
      developer.log('启动重排提醒：$result', name: 'main');
    } catch (error) {
      // 重排失败不该挡住界面；下次启动会再试。
      developer.log('启动重排提醒失败: $error', name: 'main');
    }
  }

  Future<void> _openInput() async {
    final saved = await _navigatorKey.currentState!.push<bool>(
      MaterialPageRoute(
        builder: (context) => ManualInputScreen(
          db: widget.db,
          notifications: widget.notifications,
          settings: widget.settings,
        ),
      ),
    );
    if (saved == true && mounted) {
      setState(() => _scheduleVersion++);
    }
  }

  /// 点日程/课表里的条目 → 编辑已有条目。
  Future<void> _openEntry(TimelineEntry entry) async {
    final saved = await _navigatorKey.currentState!.push<bool>(
      MaterialPageRoute(
        builder: (context) => ManualInputScreen(
          db: widget.db,
          notifications: widget.notifications,
          settings: widget.settings,
          editing: entry,
        ),
      ),
    );
    if (saved == true && mounted) {
      setState(() => _scheduleVersion++);
    }
  }

  Future<void> _openAiChat() async {
    await _navigatorKey.currentState!.push(
      MaterialPageRoute(
        builder: (context) => AiChatScreen(
          settings: widget.settings,
          db: widget.db,
          notifications: widget.notifications,
        ),
      ),
    );
    if (mounted) setState(() => _scheduleVersion++);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: '待办',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1976D2),
          surface: ivoryBackground,
        ),
        scaffoldBackgroundColor: ivoryBackground,
        // 事件/任务卡走主题色，课程卡由 TimelineItem 自己上淡色。
        // surfaceTint 必须关掉，否则 M3 又叠一层主题紫把象牙白染灰。
        cardTheme: const CardThemeData(
          color: ivoryBackground,
          surfaceTintColor: Colors.transparent,
        ),
        // 底栏默认走 M3 的 surfaceContainer（偏冷灰蓝），不跟着主题背景走，
        // 在象牙白页面上会像贴了块冷色板，显式改成同色。
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: ivoryBackground,
          indicatorColor: const Color(0xFFDCE8FA),
          surfaceTintColor: Colors.transparent,
        ),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: SafeArea(
          child: IndexedStack(
            index: _index,
            children: [
              ScheduleScreen(
                key: ValueKey('schedule_$_scheduleVersion'),
                db: widget.db,
                notifications: widget.notifications,
                permissionGranted: widget.permissionGranted,
                onOpenEntry: _openEntry,
              ),
              TimetableScreen(
                key: ValueKey('timetable_$_scheduleVersion'),
                db: widget.db,
                settings: widget.settings,
                onOpenEntry: _openEntry,
              ),
              SettingsScreen(
                settings: widget.settings,
                db: widget.db,
                notifications: widget.notifications,
                onDataChanged: () {
                  setState(() => _scheduleVersion++);
                  // 恢复备份 / 导入课表只写库不排闹钟，这里必须整体重排一次，
                  // 否则用户看到满满一屏日程，实际一条都不会响。
                  unawaited(_syncReminders());
                },
              ),
            ],
          ),
        ),
        // 2026-11-21 用户要求：AI 录入入口放在日程页，位于加号左边。
        floatingActionButton: _index == 0
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(
                    key: const Key('ai_entry'),
                    heroTag: 'fab_ai',
                    tooltip: 'AI 对话录入',
                    onPressed: _openAiChat,
                    child: const Icon(Icons.auto_awesome),
                  ),
                  const SizedBox(width: 12),
                  FloatingActionButton(
                    key: const Key('add_entry'),
                    heroTag: 'fab_add',
                    onPressed: _openInput,
                    child: const Icon(Icons.add),
                  ),
                ],
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (value) => setState(() => _index = value),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.list_alt_outlined),
              selectedIcon: Icon(Icons.list_alt),
              label: '日程',
            ),
            NavigationDestination(
              icon: Icon(Icons.grid_on_outlined),
              selectedIcon: Icon(Icons.grid_on),
              label: '课表',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }
}
