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

/// 课表块底色（2026-11-22 按用户给的参考图定）：都是低饱和马卡龙色，
/// 深色小字压在上面才读得清；七门课同屏也不会看成一团。
const List<Color> coursePalette = [
  Color(0xFFF8A5B8), // 粉
  Color(0xFF8CBBF0), // 蓝
  Color(0xFF7FD0BE), // 青
  Color(0xFFB6A4E8), // 紫
  Color(0xFFF7A876), // 橙
  Color(0xFF9BD49B), // 绿
  Color(0xFFF0C96B), // 黄
];

/// 课程取色：用户/导入设过色就用它，否则按课名算一个稳定颜色。
///
/// 用自己写的哈希而不是 `String.hashCode`：后者在同一进程内稳定，
/// 但不同 Dart 版本/不同运行之间不保证一致，会让同一门课换次启动就变色。
Color courseColorFor(TimelineEntry entry) {
  final hex = entry.colorHex;
  if (hex != null && hex.isNotEmpty) return colorFromHex(hex);
  return coursePalette[_stableHash(entry.title) % coursePalette.length];
}

int _stableHash(String value) {
  var hash = 7;
  for (final code in value.codeUnits) {
    hash = (hash * 31 + code) & 0x7FFFFFFF;
  }
  return hash;
}

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
