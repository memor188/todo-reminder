import 'package:flutter/material.dart';

import '../models/timeline.dart';

Color colorFromHex(String? hex) {
  if (hex == null || hex.isEmpty) return const Color(0xFF1976D2);
  final raw = hex.replaceAll('#', '');
  final value = int.tryParse(raw, radix: 16);
  if (value == null) return const Color(0xFF1976D2);
  return Color(raw.length == 6 ? 0xFF000000 | value : value);
}

/// 优先级配色。普通不配色（不显示标记，避免满屏花花绿绿），
/// 重要用橙、紧急用红——红橙在这一屏里没有别的含义，不会和课程色撞。
Color priorityColor(int priority) => switch (priority) {
  priorityUrgent => const Color(0xFFD32F2F),
  priorityImportant => const Color(0xFFEF6C00),
  _ => const Color(0xFF757575),
};

class TimelineItem extends StatelessWidget {
  const TimelineItem({
    super.key,
    required this.entry,
    this.onToggleTask,
    this.onTap,
  });

  final TimelineEntry entry;
  final ValueChanged<TimelineEntry>? onToggleTask;
  final ValueChanged<TimelineEntry>? onTap;

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(entry.colorHex);
    final isTask = entry.type == EntryType.task;
    // 有优先级时左侧色条跟着变，扫一眼就能挑出要紧的那几条。
    final barColor = entry.isImportant ? priorityColor(entry.priority) : color;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      color: entry.type == EntryType.course ? color.withAlpha(18) : null,
      child: ListTile(
        onTap: onTap == null ? null : () => onTap!(entry),
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
                  color: barColor,
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry.isImportant) ...[
              _PriorityTag(priority: entry.priority),
              const SizedBox(width: 6),
            ],
            Text(switch (entry.type) {
              EntryType.course => '课程',
              EntryType.event => '事件',
              EntryType.task => '任务',
            }, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }
}

class _PriorityTag extends StatelessWidget {
  const _PriorityTag({required this.priority});

  final int priority;

  @override
  Widget build(BuildContext context) {
    final color = priorityColor(priority);
    return Container(
      key: Key('priority_tag_${priorityLabel(priority)}'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        priorityLabel(priority),
        style: TextStyle(
          fontSize: 11,
          height: 1.2,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
