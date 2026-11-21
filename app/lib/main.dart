import 'package:flutter/material.dart';

import 'screens/manual_input_screen.dart';
import 'screens/schedule_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/timetable_screen.dart';
import 'services/db_service.dart';
import 'services/notification_service.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final notifications = NotificationService();
  await notifications.init();
  final granted = await notifications.requestPermissions();

  final db = DbService();
  await db.init();
  final settings = await SettingsService.load();

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

  Future<void> _openInput() async {
    final saved = await _navigatorKey.currentState!.push<bool>(
      MaterialPageRoute(
        builder: (context) => ManualInputScreen(
          db: widget.db,
          notifications: widget.notifications,
        ),
      ),
    );
    if (saved == true && mounted) {
      setState(() => _scheduleVersion++);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: '待办',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1976D2)),
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
              ),
              TimetableScreen(
                key: ValueKey('timetable_$_scheduleVersion'),
                db: widget.db,
              ),
              SettingsScreen(
                settings: widget.settings,
                db: widget.db,
                notifications: widget.notifications,
                onDataChanged: () => setState(() => _scheduleVersion++),
              ),
            ],
          ),
        ),
        floatingActionButton: _index == 0
            ? FloatingActionButton(
                key: const Key('add_entry'),
                onPressed: _openInput,
                child: const Icon(Icons.add),
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
