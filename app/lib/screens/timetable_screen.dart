import 'package:flutter/material.dart';

import '../models/timeline.dart';
import '../services/db_service.dart';
import '../widgets/timeline_item.dart';

/// V2 课表周网格：课程就地渲染周期块，事件/任务同网格不同画法。
class TimetableScreen extends StatefulWidget {
  const TimetableScreen({super.key, required this.db});

  final DbService db;

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
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

  @override
  Widget build(BuildContext context) {
    final days = List.generate(7, (i) => _monday.add(Duration(days: i)));
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
            const SizedBox(width: 38),
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Center(
                  child: Text(
                    '周${'一二三四五六日'[i]}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  itemCount: 18,
                  itemBuilder: (context, index) {
                    final hour = index + 6;
                    return SizedBox(
                      height: 76,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 38,
                            child: Text(
                              '$hour',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                          for (final day in days)
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border(
                                    left: BorderSide(
                                      color: Colors.grey.shade200,
                                    ),
                                    bottom: BorderSide(
                                      color: Colors.grey.shade200,
                                    ),
                                  ),
                                ),
                                padding: const EdgeInsets.all(2),
                                child: Column(
                                  children: [
                                    for (final entry in _entriesFor(
                                      day,
                                    ).where((e) => e.sortMinutes ~/ 60 == hour))
                                      _gridChip(entry),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _gridChip(TimelineEntry entry) {
    final color = colorFromHex(entry.colorHex);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
      decoration: BoxDecoration(
        color: switch (entry.type) {
          EntryType.course => color.withAlpha(40),
          EntryType.event => color.withAlpha(80),
          EntryType.task => Colors.white,
        },
        border: entry.type == EntryType.task
            ? Border.all(color: Colors.grey, style: BorderStyle.solid)
            : Border(left: BorderSide(color: color, width: 3)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        entry.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 10),
      ),
    );
  }
}
