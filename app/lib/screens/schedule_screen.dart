import 'package:flutter/material.dart';

import '../models/timeline.dart';
import '../services/db_service.dart';
import '../services/notification_service.dart';
import '../services/reminder_service.dart';
import '../widgets/timeline_item.dart';

/// 日程页（2026-11-22 改版）。
///
/// 两处变化：
/// 1. **去掉顶部的「11月16日 - 11月22日」**——下面那排日期格已经把这一周
///    说清楚了，上面再写一遍纯属占地方。翻周改成左右滑动（和课表页一致），
///    箭头一起去掉，省下的高度全给日程列表。
/// 2. **课程颜色跟课表页共用一份分配**（[assignCourseColors]），同一门课在
///    两页是同一种颜色，来回切不会看花。
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
  /// 以「本周」为原点的虚拟页码。左右各 260 周（约 5 年），够翻了。
  static const int originPage = 260;
  static const int pageCount = 521;

  final DateTime _baseMonday = () {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return today.subtract(Duration(days: now.weekday - 1));
  }();

  late final PageController _pageController = PageController(
    initialPage: originPage,
  );

  /// 只取它的「星期几」：翻到哪一周就显示那一周的同一个星期几。
  ///
  /// 这样翻周不必额外记状态——日期格点一下就改写它，翻页时跟着走。
  DateTime _selected = DateTime.now();

  AppData _data = const AppData(courses: [], events: [], tasks: []);
  Map<String, Color> _colors = const {};
  bool _loading = true;

  DateTime _mondayOf(int page) =>
      _baseMonday.add(Duration(days: (page - originPage) * 7));

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final data = await widget.db.queryAll();
    if (!mounted) return;
    setState(() {
      _data = data;
      _colors = assignCourseColors(data.courses);
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
    return Column(
      children: [
        if (!widget.permissionGranted)
          Container(
            width: double.infinity,
            color: Colors.orange.shade100,
            padding: const EdgeInsets.all(10),
            child: const Text('通知权限未授予，到点可能不会提醒。'),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : PageView.builder(
                  // 左右滑动翻周，和课表页同一套手势。
                  key: const Key('week_pager'),
                  controller: _pageController,
                  itemCount: pageCount,
                  itemBuilder: (context, index) => _weekPage(index),
                ),
        ),
      ],
    );
  }

  /// 一页 = 一整周（日期格 + 当天日程）。日期格跟着页面一起滑，才对得上。
  Widget _weekPage(int index) {
    final monday = _mondayOf(index);
    final days = List.generate(7, (i) => monday.add(Duration(days: i)));
    final selected = monday.add(Duration(days: _selected.weekday - 1));
    final entries = buildTimeline(
      day: selected,
      courses: _data.courses,
      events: _data.events,
      tasks: _data.tasks,
    );

    return Column(
      key: Key('week_${dateKey(monday)}'),
      children: [
        const SizedBox(height: 4),
        SizedBox(
          height: 74,
          // 用 Row + Expanded 而不是横向 ListView：7 天本来就塞得下，
          // 横向 ListView 会把这一条上的左右滑动吞掉，翻周就翻不动了。
          child: Row(
            children: [
              // 2026-11-22：删掉顶部日期范围行之后月份就看不见了。
              // 这里照抄课表页左上角的写法，只占 42dp 宽、不额外增高。
              SizedBox(
                width: 42,
                child: Center(
                  child: Text(
                    '${monday.month}月',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
              ),
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: _dayChip(
                    days[i],
                    i,
                    isSelected: dateKey(days[i]) == dateKey(selected),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: entries.isEmpty
              ? const Center(child: Text('这一天暂无日程'))
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, i) => TimelineItem(
                    entry: entries[i],
                    courseColors: _colors,
                    onToggleTask: _toggleTask,
                    onTap: widget.onOpenEntry,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _dayChip(DateTime day, int index, {required bool isSelected}) {
    return GestureDetector(
      key: Key('day_${dateKey(day)}'),
      onTap: () => setState(() => _selected = day),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
        child: Container(
          decoration: BoxDecoration(
            color: isSelected ? Colors.blue : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '周${'一二三四五六日'[index]}',
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.black54,
                  fontSize: 11,
                ),
              ),
              Text(
                '${day.day}',
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.black87,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
