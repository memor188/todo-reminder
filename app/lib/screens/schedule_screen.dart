import 'dart:async';

import 'package:flutter/material.dart';

import '../models/timeline.dart';
import '../services/db_service.dart';
import '../services/notification_service.dart';
import '../services/reminder_service.dart';
import '../theme.dart';
import '../widgets/day_timeline_list.dart';
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

  /// 分区判定用的「此刻」。60 秒推一次，过期是时间自己走出来的，
  /// 不是用户点出来的 —— 没有这个计时器，挂着页面不动，课都上完了还亮着。
  DateTime _now = DateTime.now();
  Timer? _ticker;

  /// 刚落位的条目 key（亮 400ms，让人看见它去哪了）。
  String? _flashKey;

  /// 已完成区是否展开。默认折叠，每次换日期重置。
  bool _doneExpanded = false;

  /// 已完成区超过这个条数才出现折叠控件。
  static const int doneFoldThreshold = 5;

  DateTime _mondayOf(int page) =>
      _baseMonday.add(Duration(days: (page - originPage) * 7));

  @override
  void initState() {
    super.initState();
    _load();
    _ticker = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final data = await widget.db.queryAll();
    if (!mounted) return;
    setState(() {
      _data = data;
      _colors = assignCourseColors(data.courses);
      _now = DateTime.now();
      _loading = false;
    });
  }

  /// 勾选 / 取消勾选（任务与事件都能勾，课程不参与）。
  ///
  /// 2026-11-25 改：不再先等 250ms 淡出再落库。位移/收展动画现在由
  /// [DayTimelineList] 负责，它要等数据变了才知道该往哪挪，所以这里
  /// 立刻写库、立刻重载，动画跟着新数据走。
  Future<void> _toggleEntry(TimelineEntry entry) async {
    if (entry.type == EntryType.course) return;
    final markingDone = !entry.done;

    if (entry.type == EntryType.task) {
      await widget.db.setTaskDone(entry.sourceId, done: markingDone);
      if (markingDone) {
        // 勾完了就不该再响。以前只在保存时排闹钟、勾完成时不撤，
        // 结果「已经做完的作业」到点还会弹出来。
        try {
          await widget.notifications.cancel(
            ReminderService.taskNotificationId(entry.sourceId),
          );
        } catch (_) {
          // 没有这条提醒也算正常。
        }
      }
    } else {
      await widget.db.setEventDone(entry.sourceId, done: markingDone);
    }

    await _load();
    if (!mounted) return;
    setState(() => _flashKey = entry.key);
    // 高亮由 TimelineItem 内部的 TweenAnimationBuilder 播完就停，
    // 这里不用定时器清理 —— 挂个 Timer 出去，测试会报
    // "A Timer is still pending after the widget tree was disposed"。
    // 切日期时在 _dayChip 里清掉 _flashKey 即可。
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
    final sections = buildDaySections(
      day: selected,
      courses: _data.courses,
      events: _data.events,
      tasks: _data.tasks,
      now: _now,
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
          child: sections.isEmpty
              ? const Center(child: Text('这一天暂无日程'))
              : _dayList(sections, selected),
        ),
      ],
    );
  }

  /// 一天的三段列表：正常 → 已过期 → 已完成，顺序固定不交错。
  ///
  /// 行怎么拆、怎么收展、怎么折叠全在 [DayTimelineList] 里；这里只把当天
  /// 的数据和回调递进去。
  ///
  /// key 里带日期：换日期 = 换一个列表实例，直接重排不播动画（那是整页
  /// 换内容，一次动十几条反而更乱）；同一天内勾选则复用同一个实例，
  /// 由它算出哪几行挪了位置、只给那几行播动画。
  Widget _dayList(DaySections sections, DateTime day) {
    return DayTimelineList(
      // 前缀不能和日期格的 Key('day_<日期>') 撞，撞了两个 finder 会打架。
      key: ValueKey('daylist_${dateKey(day)}'),
      day: day,
      sections: sections,
      now: _now,
      courseColors: _colors,
      doneExpanded: _doneExpanded,
      foldThreshold: doneFoldThreshold,
      flashKey: _flashKey,
      onOpenEntry: widget.onOpenEntry,
      onToggleEntry: _toggleEntry,
      onToggleFold: () => setState(() => _doneExpanded = !_doneExpanded),
    );
  }

  Widget _dayChip(DateTime day, int index, {required bool isSelected}) {
    return GestureDetector(
      key: Key('day_${dateKey(day)}'),
      onTap: () => setState(() {
        _selected = day;
        _doneExpanded = false;
        _flashKey = null;
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
        child: Container(
          decoration: BoxDecoration(
            color: isSelected ? Colors.blue : warmChip,
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
