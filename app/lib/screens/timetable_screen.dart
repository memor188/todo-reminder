import 'dart:async';

import 'package:flutter/material.dart';

import '../models/period_table.dart';
import '../models/timeline.dart';
import '../services/db_service.dart';
import '../services/settings_service.dart';
import '../theme.dart';
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
/// 当前时间线在这一周的落点（相对网格顶部的像素）。
///
/// 不在本周、或当前时刻落在作息表范围外，返回 null——那种情况下画一条线
/// 只会让人以为是 bug。抽成纯函数是为了单测能固定「现在」来验算。
double? nowLineTopFor(
  DateTime now,
  DateTime monday,
  int gridStart,
  int gridEnd,
  double pxPerMinute,
) {
  final today = DateTime(now.year, now.month, now.day);
  final weekEnd = monday.add(const Duration(days: 7));
  if (today.isBefore(monday) || !today.isBefore(weekEnd)) return null;
  final minutes = now.hour * 60 + now.minute;
  if (minutes < gridStart || minutes > gridEnd) return null;
  return (minutes - gridStart) * pxPerMinute;
}

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

  /// 每分钟多少像素：45 分钟一节 = 56dp，10 分钟课间 = 12.5dp。
  ///
  /// 2026-11-23 用户改主意：课表优先当「好看的展示页」，不再追求一屏塞下
  /// 更多课，所以从路径 A 的 0.9375 恢复到 1.25，并把省下的空间用于留白、
  /// 字号层级和色块边界。整天网格 783dp → 1044dp。
  static const double pxPerMinute = 1.25;

  /// 当前时间线的颜色。和「今天」日期胶囊同色，一眼能看出是同一套标记。
  static const Color nowLineColor = Color(0xFF1976D2);

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

  /// 当前时间线每分钟动一次。用 Timer 而不是依赖页面重建——
  /// 用户可能就停在这一页盯着看，不刷新的话那条线会一直是打开时的位置。
  DateTime _now = DateTime.now();
  Timer? _clockTimer;

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
    _clockTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
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
    return _loading
        ? const Center(child: CircularProgressIndicator())
        : Stack(
            children: [
              PageView.builder(
                // 手势左右滑动翻周。网格本身是纵向滚动，两者方向不同不冲突。
                key: const Key('tt_week_pager'),
                controller: _pageController,
                itemCount: pageCount,
                onPageChanged: (index) => setState(() => _page = index),
                itemBuilder: (context, index) => _weekPage(_mondayOf(index)),
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
          );
  }

  /// 一页 = 一整周（星期表头 + 网格）。表头跟着页面一起滑，日期才对得上。
  ///
  /// 顶部原来那行「11月16日 - 11月22日」+ 左右箭头已经删掉（2026-11-22 用户
  /// 要求）：表头本来就把每一天的日期写出来了，再写一遍纯属重复；翻周改由
  /// 左右滑动负责，翻到别的周时右边会飘出「回到本周」。
  Widget _weekPage(DateTime monday) {
    final days = List.generate(7, (i) => monday.add(Duration(days: i)));
    final now = _now;
    // 只有「本周」且现在落在作息表范围内才画时间线
    final lineTop = nowLineTopFor(now, monday, _gridStart, _gridEnd, pxPerMinute);
    final todayIndex = now.weekday - 1;
    return Column(
      key: Key('tt_week_${dateKey(monday)}'),
      children: [
        Row(
          children: [
            SizedBox(
              width: gutterWidth,
              child: Center(
                child: Text(
                  '${monday.month}月',
                  style: const TextStyle(fontSize: 11, color: warmInkSoft),
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
                  _timeGutter(nowLineTop: lineTop),
                  for (var i = 0; i < days.length; i++)
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) => _dayColumn(
                          days[i],
                          constraints.maxWidth,
                          isToday:
                              days[i].year == now.year &&
                              days[i].month == now.month &&
                              days[i].day == now.day,
                          nowLineTop: i == todayIndex ? lineTop : null,
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

  /// 星期 + 日期。今天用主题蓝胶囊压住日期，和其他天区分开。
  Widget _dayHeader(DateTime day, {required bool isToday}) {
    return Column(
      children: [
        Text(
          '一二三四五六日'[day.weekday - 1],
          style: const TextStyle(fontSize: 11, color: warmInkSoft),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: isToday
              ? BoxDecoration(
                  color: nowLineColor,
                  borderRadius: BorderRadius.circular(12),
                )
              : null,
          child: Text(
            '${day.day}',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: isToday ? Colors.white : warmInk,
            ),
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  /// 左栏：第 N 节 + 起 / 止时刻。当前时间在右边缘用一个小圆点标出，
  /// 和今天那一列的横线首尾呼应。
  Widget _timeGutter({double? nowLineTop}) {
    return SizedBox(
      width: gutterWidth,
      height: _totalHeight,
      child: Stack(
        children: [
          if (nowLineTop != null)
            Positioned(
              top: nowLineTop - 3,
              right: 1,
              child: Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: nowLineColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
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
                      fontWeight: FontWeight.w500,
                      color: warmInk,
                    ),
                  ),
                  Text(
                    slot.start,
                    style: const TextStyle(
                      fontSize: 9,
                      height: 1.2,
                      color: warmInkFaint,
                    ),
                  ),
                  Text(
                    slot.end,
                    style: const TextStyle(
                      fontSize: 9,
                      height: 1.2,
                      color: warmInkFaint,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _dayColumn(
    DateTime day,
    double width, {
    required bool isToday,
    double? nowLineTop,
  }) {
    final slots = layoutDay(_entriesFor(day));
    // 横线是背景，不应该和课程块抢注意力。跟着象牙白背景一起调暖。
    const line = warmDivider;
    return Container(
      width: width,
      height: _totalHeight,
      decoration: BoxDecoration(
        color: isToday ? const Color(0xFF2A6FD6).withAlpha(8) : null,
        border: const Border(left: BorderSide(color: line, width: 0.5)),
      ),
      child: Stack(
        children: [
          // 每节起点的横线，把网格感做出来
          for (final slot in _table.slots)
            Positioned(
              top: (parseHm(slot.start) - _gridStart) * pxPerMinute,
              left: 0,
              right: 0,
              child: const SizedBox(height: 0.5, child: ColoredBox(color: line)),
            ),
          for (final slot in slots) _block(slot, width),
          // 当前时间线压在课程块之上，否则会被块盖住看不见
          if (nowLineTop != null)
            Positioned(
              top: nowLineTop,
              left: 0,
              right: 0,
              child: Container(height: 1.2, color: nowLineColor),
            ),
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

    // 2026-11-23「自然融合」：课程块不再铺一层 91% 不透明的原色（像贴纸），
    // 而是先和象牙白按 70:30 混成不透明色。混完之后块和背景是同一个底子，
    // 只留下色相差别，不再有硬邦邦的边界。
    // 事件型要一眼抓住注意力，保留浓底 + 白字；任务型仍是留白描边。
    // 「非本周」换个思路：不再只是把原色调淡，而是压到暖灰底上，
    // 让它读起来是「这节课不在本周」而不是「这门课颜色很浅」。
    final Color fill = switch (entry.type) {
      EntryType.course => isGhost
          ? Color.alphaBlend(base.withAlpha(30), warmChip)
          : Color.alphaBlend(base.withAlpha(178), ivoryBackground),
      EntryType.event => base.withAlpha(150),
      EntryType.task => ivoryBackground,
    };
    final Color textColor = switch (entry.type) {
      EntryType.course => isGhost ? warmInkFaint : warmInk,
      EntryType.event => Colors.white,
      EntryType.task => warmInk,
    };

    // 这两条阈值是**绝对 dp**，不会跟着 pxPerMinute 自动缩放。
    // 单节块从 56.3dp 缩到 42.2dp 之后，原来的 52/44 会让「@教室」和
    // 「非本周」标签同时消失（样图里周三体育的 @操场 就是这么没的）。
    // 2026-11-22 路径 A：一起降到 40/36，保住这两项信息。
    final shortLocation = displayLocation(entry.location);
    final showLocation = height >= 40 && shortLocation.isNotEmpty;
    final showGhostTag = isGhost && height >= 36;

    /// 按块高动态分配「字号 / 行数预算」，不再写死一档。
    ///
    /// 起因：缩短 25% 后，两节连堂只剩 94dp，长课名（ELC1综合英语与沟通能力）
    /// 要 4 行、地点 2 行、再加「非本周」标签，真机上直接撑出红色 OVERFLOWED。
    /// 单节块 42dp 更挤，原来那种「全都按常规字号排」的做法必然溢出。
    ///
    /// 现在的算法：先按高度选一套字号，再把地点和标签占掉的高度扣掉，
    /// 剩下的全给标题，标题超了就省略号——信息种类不丢，长名字让位。
    // 展示优先：内边距给足 4dp，只有极端矮的块才收紧。
    final compact = height < 50;
    final middle = !compact && height < 120;
    // 单节块再省 1dp 内边距：56dp 里塞标题 + 地点 + 标签，差这 1dp 就会溢出
    final padV = compact ? 2.0 : (height < 70 ? 3.0 : 4.0);

    final titleFont = compact ? 9.5 : 11.5;
    final titleLineFactor = compact ? 1.12 : 1.2;
    final titleLineHeight = titleFont * titleLineFactor;

    final locFont = compact ? 8.0 : 9.0;
    final locLineHeight = locFont * 1.2;
    final locTop = compact ? 1.0 : 3.0;
    // 灰块要多留一行给「非本周」标签，普通块把教室名多显示一行。
    // 这样两节连堂的 ELC1 既能看全课名，也不会把 @东海岸-E教201-阶梯 掐掉。
    final locMaxLines = compact
        ? 1
        : (height < 70 ? 1 : (middle ? (showGhostTag ? 2 : 3) : 4));

    final tagFont = compact ? 7.0 : 8.0;
    final tagPadV = compact ? 0.0 : 1.0;
    final tagHeight = showGhostTag ? tagFont * 1.1 + tagPadV : 0.0;

    final innerHeight = height - 2 * padV;
    final reserved =
        (showLocation ? (locLineHeight + locTop) * locMaxLines : 0) + tagHeight;
    final titleMaxLines = ((innerHeight - reserved) / titleLineHeight)
        .floor()
        .clamp(1, 8)
        .toInt();

    return Positioned(
      top: top,
      // 列间距 2dp → 6dp：色块之间留出象牙白呼吸缝，连成一片的「色墙」就散开了。
      left: left + 3,
      width: slotWidth - 6,
      height: height,
      child: GestureDetector(
        key: Key('grid_${entry.key}'),
        onTap: widget.onOpenEntry == null
            ? null
            : () => widget.onOpenEntry!(entry),
        child: Container(
          // 去掉左侧深色竖条后不再需要裁切子元素，但保留 clip 以防圆角
          // 和描边在窄块上出现毛边。
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: fill,
            border: entry.type == EntryType.task
                ? Border.all(color: const Color(0xFFD6CCBC))
                : (isGhost
                    ? Border.all(
                        color: Color.alphaBlend(base.withAlpha(70), warmChip),
                        width: 0.8,
                      )
                    : null),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  // 没有竖条了，四边统一 4dp。竖条省下的 3dp 刚好补回
                  // 列间距挤掉的空间，长课名不会因此多断一行。
                  padding: EdgeInsets.only(
                    left: 4,
                    right: 4,
                    top: padV,
                    bottom: padV,
                  ),
                  child: ClipRect(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                Text(
                  entry.title,
                  // 行数按上面算出来的预算，超了就省略号，不再写死档位。
                  maxLines: titleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: titleFont,
                    height: titleLineFactor,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                if (showLocation)
                  Padding(
                    padding: EdgeInsets.only(top: locTop),
                    child: Text(
                      '@$shortLocation',
                      // 一天只有 45dp 宽，窄栏里 13 个字的教室名要好几行；
                      // 行数同样按块高给（短块 1 行，高块 4 行）。
                      maxLines: locMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: locFont,
                        height: 1.2,
                        color: entry.type == EntryType.event
                            ? Colors.white70
                            : (isGhost ? warmInkFaint : warmInkSoft),
                      ),
                    ),
                  ),
                const Spacer(),
                if (showGhostTag)
                  Container(
                    // 窄列只有约 31dp 文字区：三个字 8px 已经占 24dp，
                    // 左右各 4dp 内边距会把它挤成「非本 / 周」两行，收紧到 2dp。
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 1.5 : 2,
                      vertical: tagPadV,
                    ),
                    decoration: BoxDecoration(
                      // 用不透明色：半透明小-chip 压在灰块上会被阴影/底色透脏
                      color: ivoryBackground,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      '非本周',
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: tagFont,
                        height: 1.1, // 和上面 tagHeight 的估算保持一致
                        color: warmInkFaint,
                      ),
                    ),
                  ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
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
