import 'package:flutter/material.dart';

import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final notifications = NotificationService();
  await notifications.init();
  final granted = await notifications.requestPermissions();

  runApp(V0App(notifications: notifications, permissionGranted: granted));
}

class V0App extends StatelessWidget {
  const V0App({
    super.key,
    required this.notifications,
    required this.permissionGranted,
  });

  final NotificationService notifications;
  final bool permissionGranted;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '待办 App V0',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1976D2)),
        useMaterial3: true,
      ),
      home: V0HomePage(
        notifications: notifications,
        permissionGranted: permissionGranted,
      ),
    );
  }
}

class V0HomePage extends StatefulWidget {
  const V0HomePage({
    super.key,
    required this.notifications,
    required this.permissionGranted,
  });

  final NotificationService notifications;
  final bool permissionGranted;

  @override
  State<V0HomePage> createState() => _V0HomePageState();
}

class _V0HomePageState extends State<V0HomePage> {
  final TextEditingController _titleController = TextEditingController();
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  String? _message;

  @override
  void initState() {
    super.initState();
    if (!widget.permissionGranted) {
      _message = '通知权限未授予，请到系统设置开启，否则到点不会弹通知。';
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
    );
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _scheduleAtPickedTime() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _message = '请先输入事项');
      return;
    }

    final now = DateTime.now();
    var target = DateTime(
      now.year,
      now.month,
      now.day,
      _time.hour,
      _time.minute,
    );
    // 选的时间已过 → 顺延到明天（V0 只验链路，不做复杂日历）
    if (!target.isAfter(now)) target = target.add(const Duration(days: 1));

    try {
      await widget.notifications.schedule(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000 % 100000,
        title: title,
        body: '到点了：$title',
        eventTime: target,
      );
      setState(() => _message = '已设置：$title → ${_fmt(target)}');
    } catch (e) {
      setState(() => _message = '设置失败：$e');
    }
  }

  Future<void> _showNow() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _message = '请先输入事项');
      return;
    }
    try {
      await widget.notifications.showNow(
        id: 999998,
        title: title,
        body: '这是即时诊断通知（脚手架，V1 删除）',
      );
      setState(() => _message = '即时通知已发送');
    } catch (e) {
      setState(() => _message = '即时通知失败：$e');
    }
  }

  Future<void> _scheduleTenSecondTest() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _message = '请先输入事项');
      return;
    }
    try {
      await widget.notifications.scheduleTestNotification(title);
      setState(() => _message = '测试已设置：10 秒后弹通知（脚手架，V1 删除）');
    } catch (e) {
      setState(() => _message = '测试设置失败：$e');
    }
  }

  String _fmt(DateTime t) =>
      '${t.month}月${t.day}日 ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('待办 App V0 · 通知链路验证')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'V0 只验证通知链路，无列表、无存储、无 AI。',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            TextField(
              key: const Key('title_field'),
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: '事项',
                border: OutlineInputBorder(),
                hintText: '例如：测试提醒',
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              key: const Key('time_picker_tile'),
              title: const Text('提醒时间'),
              trailing: Text(
                '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
                style: const TextStyle(fontSize: 18),
              ),
              onTap: _pickTime,
              tileColor: Colors.blue.shade50,
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('schedule_button'),
              onPressed: _scheduleAtPickedTime,
              child: const Text('设置提醒'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const Key('now_button'),
              onPressed: _showNow,
              child: const Text('立即弹通知（诊断用，V1 删除）'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const Key('test_button'),
              onPressed: _scheduleTenSecondTest,
              child: const Text('10 秒后测试（脚手架，V1 删除）'),
            ),
            const SizedBox(height: 24),
            if (_message != null)
              Text(
                _message!,
                key: const Key('status_message'),
                style: const TextStyle(fontSize: 15),
              ),
          ],
        ),
      ),
    );
  }
}
