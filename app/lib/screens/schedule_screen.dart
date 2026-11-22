import 'package:flutter/material.dart';

import '../models/timeline.dart';
import '../services/db_service.dart';
import '../services/notification_service.dart';
import '../services/reminder_service.dart';
import '../widgets/timeline_item.dart';

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({
    super.key,
    required this.db,
    required this.notifications,
    required this.permissionGranted,
    this.onOpenEntry,
  });

  final DbService db;
  final NotificationService notifications;
  final bool permissionGranted;

  /// 点条目进入编辑页（2026-11-21 用户要求）。
  final ValueChanged<TimelineEntry>? onOpenEntry;

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  DateTime _selected = DateTime.now();
  AppData _data = const AppData(courses: [], events: [], tasks: []);
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await widget.db.queryAll();
    if (!mounted) return;
    setState(() {
      _data = data;
      _loading = false;
    });
  }

  Future<void> _toggleTask(TimelineEntry entry) async {
    await widget.db.setTaskDone(entry.sourceId, done: true);
    // 勾完了就不该再响。以前只在保存时排闹钟、勾完成时不撤，
    // 结果「已经做完的作业」到点还会弹出来。
    try {
      await widget.notifications.cancel(
        ReminderService.taskNotificationId(entry.sourceId),
      );
    } catch (_) {
      // 没有这条提醒也算正常。
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final monday = _selected.subtract(Duration(days: _selected.weekday - 1));
    final days = List.generate(7, (i) => monday.add(Duration(days: i)));
    final entries = buildTimeline(
      day: _selected,
      courses: _data.courses,
      events: _data.events,
      tasks: _data.tasks,
    );

    return Column(
      children: [
        if (!widget.permissionGranted)
          Container(
            width: double.infinity,
            color: Colors.orange.shade100,
            padding: const EdgeInsets.all(10),
            child: const Text('通知权限未授予，到点可能不会提醒。'),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              key: const Key('prev_week'),
              icon: const Icon(Icons.chevron_left),
              onPressed: () => setState(
                () => _selected = _selected.subtract(const Duration(days: 7)),
              ),
            ),
            Text(
              '${monday.month}月${monday.day}日 - ${days.last.month}月${days.last.day}日',
              style: const TextStyle(color: Colors.grey),
            ),
            IconButton(
              key: const Key('next_week'),
              icon: const Icon(Icons.chevron_right),
              onPressed: () => setState(
                () => _selected = _selected.add(const Duration(days: 7)),
              ),
            ),
          ],
        ),
        SizedBox(
          height: 78,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: 7,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final day = days[index];
              final selected = dateKey(day) == dateKey(_selected);
              return GestureDetector(
                key: Key('day_${dateKey(day)}'),
                onTap: () => setState(() => _selected = day),
                child: Container(
                  width: 54,
                  decoration: BoxDecoration(
                    color: selected ? Colors.blue : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '周${const ['一', '二', '三', '四', '五', '六', '日'][index]}',
                        style: TextStyle(
                          color: selected ? Colors.white : Colors.black54,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        '${day.day}',
                        style: TextStyle(
                          color: selected ? Colors.white : Colors.black87,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : entries.isEmpty
              ? const Center(child: Text('这一天暂无日程'))
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) => TimelineItem(
                    entry: entries[index],
                    onToggleTask: _toggleTask,
                    onTap: widget.onOpenEntry,
                  ),
                ),
        ),
      ],
    );
  }
}
