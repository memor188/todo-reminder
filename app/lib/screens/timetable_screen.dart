import 'package:flutter/material.dart';

import '../models/timeline.dart';
import '../services/db_service.dart';
import '../widgets/timeline_item.dart';

/// 课表周网格（2026-11-21 按用户要求重做）：
/// - 时间轴 08:00–23:00，两小时为一段；
/// - 有开始/结束时间的条目按真实区间铺满对应时段（08:00–09:40 占约 5/6 段）；
/// - 无结束时间的条目按 1 小时撑开；重叠条目并排平分宽度。
class TimetableScreen extends StatefulWidget {
  const TimetableScreen({super.key, required this.db, this.onOpenEntry});

  final DbService db;
  final void Function(TimelineEntry entry)? onOpenEntry;

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  /// 网格起点与终点（当天分钟数）。
  static const int gridStartMinutes = 8 * 60;
  static const int gridEndMinutes = 23 * 60;

  /// 一小时占多少像素。两小时一段 = 112px。
  static const double pxPerHour = 56;

  static const int segmentHours = 2;

  DateTime _monday = DateTime.now().subtract(
    Duration(days: DateTime.now().weekday - 1),
  );
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

  List<TimelineEntry> _entriesFor(DateTime day) => buildTimeline(
    day: day,
    courses: _data.courses,
    events: _data.events,
    tasks: _data.tasks,
  );

  double get _totalHeight =>
      (gridEndMinutes - gridStartMinutes) / 60 * pxPerHour;

  @override
  Widget build(BuildContext context) {
    final days = List.generate(7, (i) => _monday.add(Duration(days: i)));
    final now = DateTime.now();
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              key: const Key('tt_prev_week'),
              icon: const Icon(Icons.chevron_left),
              onPressed: () => setState(
                () => _monday = _monday.subtract(const Duration(days: 7)),
              ),
            ),
            Text(
              '${_monday.month}月${_monday.day}日 - '
              '${days.last.month}月${days.last.day}日',
              style: const TextStyle(color: Colors.grey),
            ),
            IconButton(
              key: const Key('tt_next_week'),
              icon: const Icon(Icons.chevron_right),
              onPressed: () => setState(
                () => _monday = _monday.add(const Duration(days: 7)),
              ),
            ),
          ],
        ),
        Row(
          children: [
            const SizedBox(width: 40),
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Column(
                  children: [
                    Text(
                      '周${'一二三四五六日'[i]}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    Text(
                      '${days[i].day}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color:
                            days[i].year == now.year &&
                                days[i].month == now.month &&
                                days[i].day == now.day
                            ? Colors.blue
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  child: SizedBox(
                    height: _totalHeight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 40,
                          height: _totalHeight,
                          child: Stack(
                            children: [
                              for (
                                var hour = gridStartMinutes ~/ 60;
                                hour * 60 < gridEndMinutes;
                                hour += segmentHours
                              )
                                Positioned(
                                  top:
                                      (hour * 60 - gridStartMinutes) /
                                      60 *
                                      pxPerHour,
                                  left: 0,
                                  right: 0,
                                  child: Text(
                                    '$hour',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
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

  Widget _dayColumn(DateTime day, double width, {required bool isToday}) {
    final slots = layoutDay(_entriesFor(day));
    return Container(
      width: width,
      height: _totalHeight,
      decoration: BoxDecoration(
        color: isToday ? Colors.blue.withAlpha(8) : null,
        border: Border(left: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Stack(
        children: [
          // 两小时一段的横线
          for (
            var minutes = gridStartMinutes;
            minutes < gridEndMinutes;
            minutes += segmentHours * 60
          )
            Positioned(
              top: (minutes - gridStartMinutes) / 60 * pxPerHour,
              left: 0,
              right: 0,
              child: Container(height: 1, color: Colors.grey.shade200),
            ),
          for (final slot in slots) _block(slot, width),
        ],
      ),
    );
  }

  Widget _block(GridSlot slot, double columnWidth) {
    final entry = slot.entry;
    final color = colorFromHex(entry.colorHex);
    final start = slot.startMinutes.clamp(gridStartMinutes, gridEndMinutes);
    final end = slot.endMinutes.clamp(gridStartMinutes, gridEndMinutes);
    final top = (start - gridStartMinutes) / 60 * pxPerHour;
    final height = ((end - start) / 60 * pxPerHour).clamp(22.0, _totalHeight);
    final slotWidth = columnWidth / slot.columns;
    final left = slotWidth * slot.column;

    final fill = switch (entry.type) {
      EntryType.course => color.withAlpha(38),
      EntryType.event => color.withAlpha(90),
      EntryType.task => Colors.white,
    };

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
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
          decoration: BoxDecoration(
            color: fill,
            border: entry.type == EntryType.task
                ? Border.all(color: Colors.grey.shade400)
                : Border(left: BorderSide(color: color, width: 3)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: ClipRect(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  maxLines: height > 52 ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1.2,
                    color: entry.type == EntryType.event
                        ? Colors.white
                        : Colors.black87,
                  ),
                ),
                if (height > 40)
                  Text(
                    entry.timeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      color: entry.type == EntryType.event
                          ? Colors.white70
                          : Colors.black54,
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
