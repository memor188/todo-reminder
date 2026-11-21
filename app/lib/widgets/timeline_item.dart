import 'package:flutter/material.dart';

import '../models/timeline.dart';

Color colorFromHex(String? hex) {
  if (hex == null || hex.isEmpty) return const Color(0xFF1976D2);
  final raw = hex.replaceAll('#', '');
  final value = int.tryParse(raw, radix: 16);
  if (value == null) return const Color(0xFF1976D2);
  return Color(raw.length == 6 ? 0xFF000000 | value : value);
}

class TimelineItem extends StatelessWidget {
  const TimelineItem({super.key, required this.entry, this.onToggleTask});

  final TimelineEntry entry;
  final ValueChanged<TimelineEntry>? onToggleTask;

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(entry.colorHex);
    final isTask = entry.type == EntryType.task;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      color: entry.type == EntryType.course ? color.withAlpha(18) : null,
      child: ListTile(
        leading: isTask
            ? IconButton(
                key: Key('toggle_${entry.key}'),
                icon: const Icon(Icons.radio_button_unchecked),
                color: Colors.grey.shade700,
                onPressed: () => onToggleTask?.call(entry),
              )
            : Container(
                width: 4,
                height: 44,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
        title: Text(
          entry.title,
          style: TextStyle(
            decoration: entry.done ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: Text(
          [
            entry.timeLabel,
            if (entry.location != null && entry.location!.isNotEmpty)
              entry.location!,
          ].join('  ·  '),
        ),
        trailing: Text(switch (entry.type) {
          EntryType.course => '课程',
          EntryType.event => '事件',
          EntryType.task => '任务',
        }, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      ),
    );
  }
}
