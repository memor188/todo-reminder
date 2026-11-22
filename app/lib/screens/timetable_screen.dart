import 'package:flutter/material.dart';

import '../models/period_table.dart';
import '../models/timeline.dart';
import '../services/db_service.dart';
import '../services/settings_service.dart';
import '../widgets/timeline_item.dart';

/// 课表周网格（2026-11-22 按用户给的参考图重做）。
///
/// 三处和上一版不同：
/// 1. 左栏从「整点刻度」换成**节次**（第 N 节 + 起止时刻），跟教务系统的
///    「第 3-5 节」对得上；
/// 2. 课程块是**按课名稳定取色**的马卡龙色块，标题 + @地点，一眼分得清哪门课；
/// 3. 本周不上的课**照样画出来**，灰着并标「非本周」——课表的价值在于看到全貌，
///    而不是只看到"这一周要上的"。
///
/// 位置仍按真实分钟数换算（[layoutDay]），所以 08:00–09:40 的课自然压在
/// 第 1、2 节两行上，事件、任务这类不对齐节次的条目也能落在正确高度。
class TimetableScreen extends StatefulWidget {
  const TimetableScreen({
    super.key,
    required this.db,
    required this.settings,
    this.onOpenEntry,
  });

  final DbService db;
  final SettingsService settings;
  final void Function(TimelineEntry entry)? onOpenEntry;

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  /// 左栏宽度（节次序号 + 起止时刻）。
  static const double gutterWidth = 46;

  /// 每分钟多少像素：45 分钟一节 = 56px，10 分钟课间 = 12.5px。
  static const double pxPerMinute = 1.25;

  /// 以「本周」为原点的虚拟页码。左右各 260 周（约 5 年），够翻了。
  static const int originPage = 260;
  static const int pageCount = 521;

  final DateTime _baseMonday = () {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return today.subtract(Duration(days: now.weekday - 1));
  }();

  int _page = originPage;
  late final PageController _pageController = PageController(
    initialPage: originPage,
  );

  AppData _data = const AppData(courses: [], events: [], tasks: []);

  /// 课名 → 底色，整屏统一分配（见 [assignCourseColors]），撞色会自动错开。
  Map<String, Color> _colors = const {};
  bool _loading = true;

  PeriodTable get _table => widget.settings.periodTable;

  DateTime _mondayOf(int page) =>
      _baseMonday.add(Duration(days: (page - originPage) * 7));

  /// 左右滑动由 PageView 负责；箭头留着当辅助（也告诉用户这个方向能翻）。
  void _goToPage(int page) {
    final target = page.clamp(0, pageCount - 1);
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

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
      _colors = assignCourseColors(data.courses);
      _loading = false;
    });
  }

  int get _gridStart =>
      _table.isEmpty ? 8 * 60 : parseHm(_table.slots.first.start);

  int get _gridEnd =>
      _table.isEmpty ? 22 * 60 : parseHm(_table.slots.last.end);

  double get _totalHeight => (_gridEnd - _gridStart) * pxPerMinute;

  /// 当天所有要画的条目：本周的（课程/事件/任务）+ 本周不上但课表里有的课。
  List<TimelineEntry> _entriesFor(DateTime day) {
    final base = buildTimeline(
      day: day,
      courses: _data.courses,
      events: _data.events,
      tasks: _data.tasks,
    );
    final ghosts = <TimelineEntry>[];
    for (final course in _data.courses) {
      final grid = expandCourseForGrid(course, day);
      if (grid.isNotEmpty && !grid.first.isThisWeek) ghosts.add(grid.first);
    }
    return [...base, ...ghosts];
  }

  @override
  Widget build(BuildContext context) {
    final monday = _mondayOf(_page);
    final days = List.generate(7, (i) => monday.add(Duration(days: i)));
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              key: const Key('tt_prev_week'),
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _goToPage(_page - 1),
            ),
            Text(
              '${monday.month}月${monday.day}日 - '
              '${days.last.month}月${days.last.day}日',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            IconButton(
              key: const Key('tt_next_week'),
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _goToPage(_page + 1),
            ),
          ],
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    PageView.builder(
                      // 手势左右滑动翻周。网格本身是纵向滚动，两者方向不同不冲突。
                      key: const Key('tt_week_pager'),
                      controller: _pageController,
                      itemCount: pageCount,
                      onPageChanged: (index) => setState(() => _page = index),
                      itemBuilder: (context, index) =>
                          _weekPage(_mondayOf(index)),
                    ),
                    if (_page != originPage)
                      Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: _BackToThisWeekButton(
                            onTap: () => _goToPage(originPage),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  /// 一页 = 一整周（星期表头 + 网格）。表头跟着页面一起滑，日期才对得上。
  Widget _weekPage(DateTime monday) {
    final days = List.generate(7, (i) => monday.add(Duration(days: i)));
    final now = DateTime.now();
    return Column(
      children: [
        Row(
          children: [
            SizedBox(
              width: gutterWidth,
              child: Center(
                child: Text(
                  '${monday.month}月',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            ),
            for (final day in days)
              Expanded(
                child: _dayHeader(
                  day,
                  isToday:
                      day.year == now.year &&
                      day.month == now.month &&
                      day.day == now.day,
                ),
              ),
          ],
        ),
        const Divider(height: 8, thickness: 0.5),
        Expanded(
          child: SingleChildScrollView(
            child: SizedBox(
              height: _totalHeight + 12,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _timeGutter(),
                  for (final day in days)
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) => _dayColumn(
                          day,
                          constraints.maxWidth,
                          isToday:
                              day.year == now.year &&
                              day.month == now.month &&
                              day.day == now.day,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 星期 + 日期。今天用深色胶囊压住日期，和其他天区分开。
  Widget _dayHeader(DateTime day, {required bool isToday}) {
    return Column(
      children: [
        Text(
          '一二三四五六日'[day.weekday - 1],
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: isToday
              ? BoxDecoration(
                  color: const Color(0xFF22252A),
                  borderRadius: BorderRadius.circular(9),
                )
              : null,
          child: Text(
            '${day.day}',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: isToday ? Colors.white : Colors.black87,
            ),
          ),
        ),
        const SizedBox(height: 2),
      ],
    );
  }

  /// 左栏：第 N 节 + 起 / 止时刻。
  Widget _timeGutter() {
    return SizedBox(
      width: gutterWidth,
      height: _totalHeight,
      child: Stack(
        children: [
          for (final slot in _table.slots)
            Positioned(
              top: (parseHm(slot.start) - _gridStart) * pxPerMinute - 4,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  Text(
                    slot.label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  Text(
                    slot.start,
                    style: const TextStyle(
                      fontSize: 9,
                      height: 1.2,
                      color: Colors.grey,
                    ),
                  ),
                  Text(
                    slot.end,
                    style: const TextStyle(
                      fontSize: 9,
                      height: 1.2,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _dayColumn(DateTime day, double width, {required bool isToday}) {
    final slots = layoutDay(_entriesFor(day));
    return Container(
      width: width,
      height: _totalHeight,
      decoration: BoxDecoration(
        color: isToday ? const Color(0xFF2A6FD6).withAlpha(10) : null,
        border: Border(left: BorderSide(color: Colors.grey.shade200, width: 0.5)),
      ),
      child: Stack(
        children: [
          // 每节起点的横线，把网格感做出来
          for (final slot in _table.slots)
            Positioned(
              top: (parseHm(slot.start) - _gridStart) * pxPerMinute,
              left: 0,
              right: 0,
              child: Container(height: 0.5, color: Colors.grey.shade200),
            ),
          for (final slot in slots) _block(slot, width),
        ],
      ),
    );
  }

  Widget _block(GridSlot slot, double columnWidth) {
    final entry = slot.entry;
    final isGhost = !entry.isThisWeek;
    final base =
        _colors[entry.title] ??
        courseColorFor(entry);
    final start = slot.startMinutes.clamp(_gridStart, _gridEnd);
    final end = slot.endMinutes.clamp(_gridStart, _gridEnd);
    final top = (start - _gridStart) * pxPerMinute;
    final height = ((end - start) * pxPerMinute).clamp(18.0, _totalHeight);
    final slotWidth = columnWidth / slot.columns;
    final left = slotWidth * slot.column;

    // 课程用低饱和底色 + 深色字；事件用浓一点的底色 + 白字；任务留白描边。
    final Color fill = switch (entry.type) {
      EntryType.course => isGhost ? base.withAlpha(46) : base.withAlpha(232),
      EntryType.event => base.withAlpha(150),
      EntryType.task => Colors.white,
    };
    final Color textColor = switch (entry.type) {
      EntryType.course => isGhost ? Colors.black45 : const Color(0xFF2B2B2B),
      EntryType.event => Colors.white,
      EntryType.task => Colors.black87,
    };

    final showLocation = height >= 52 && (entry.location ?? '').isNotEmpty;
    final showGhostTag = isGhost && height >= 44;

    return Positioned(
      top: top,
      left: left + 1,
      width: slotWidth - 2,
      height: height,
      child: GestureDetector(
        key: Key('grid_${entry.key}'),
        onTap: widget.onOpenEntry == null
            ? null
            : () => widget.onOpenEntry!(entry),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          decoration: BoxDecoration(
            color: fill,
            border: entry.type == EntryType.task
                ? Border.all(color: Colors.grey.shade400)
                : (isGhost
                      ? Border.all(color: base.withAlpha(90), width: 0.8)
                      : null),
            borderRadius: BorderRadius.circular(7),
          ),
          child: ClipRect(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  maxLines: height > 120 ? 8 : (height > 70 ? 5 : 2),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.18,
                    fontWeight: FontWeight.w500,
                    color: textColor,
                  ),
                ),
                if (showLocation)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '@${entry.location}',
                      // 一天只有 45dp 宽，窄栏里 13 个字的教室名要 4 行才放得下
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 8.5,
                        height: 1.2,
                        color: entry.type == EntryType.event
                            ? Colors.white70
                            : Colors.black54,
                      ),
                    ),
                  ),
                const Spacer(),
                if (showGhostTag)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(200),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const Text(
                      '非本周',
                      style: TextStyle(fontSize: 8, color: Colors.black45),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 翻到别的周时飘在右边的小按钮，一键回到本周。
class _BackToThisWeekButton extends StatelessWidget {
  const _BackToThisWeekButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('tt_back_to_this_week'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF3A3F45).withAlpha(225),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(8),
            bottomLeft: Radius.circular(8),
          ),
        ),
        child: const SizedBox(
          width: 14,
          child: Text(
            '回到本周',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, height: 1.25, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
