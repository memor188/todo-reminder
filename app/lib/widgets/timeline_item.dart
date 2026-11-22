import 'package:flutter/material.dart';

import '../models/course.dart';
import '../models/timeline.dart';
import '../theme.dart';

Color colorFromHex(String? hex) {
  if (hex == null || hex.isEmpty) return const Color(0xFF1976D2);
  final raw = hex.replaceAll('#', '');
  final value = int.tryParse(raw, radix: 16);
  if (value == null) return const Color(0xFF1976D2);
  return Color(raw.length == 6 ? 0xFF000000 | value : value);
}

/// 教室里重复的校区前缀在窄栏里纯占字数，展示时剥掉。
///
/// 只影响显示，原始值照旧存库——编辑页看到的还是完整地址。
/// 汕头大学两个校区：`东海岸-` 和 `金平-`。
String displayLocation(String? raw) {
  if (raw == null) return '';
  var value = raw.trim();
  const prefixes = ['东海岸-', '金平-', '东海岸', '金平'];
  for (final prefix in prefixes) {
    if (value.startsWith(prefix) && value.length > prefix.length) {
      value = value.substring(prefix.length).trimLeft();
      break;
    }
  }
  return value;
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
///
/// 备选色 10 个而不是刚够用的 7 个：真课表一学期十几门课，色少了必然撞色，
/// 相邻两天两门课同色会让人以为是一门课。
const List<Color> coursePalette = [
  Color(0xFFF8A5B8), // 粉
  Color(0xFF8CBBF0), // 蓝
  Color(0xFF7FD0BE), // 青
  Color(0xFFB6A4E8), // 紫
  Color(0xFFF7A876), // 橙
  Color(0xFF9BD49B), // 绿
  Color(0xFFF0C96B), // 黄
  Color(0xFF86CFE0), // 湖蓝
  Color(0xFFEFA3C8), // 玫红
  Color(0xFFA9B4EE), // 靛
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

/// 给一屏课程统一配色：先按课名哈希取色，撞了就顺延到下一个还没被占的色。
///
/// 为什么不是每门课各自哈希就完事：调色板只有 10 个，十几门课必然撞色，
/// 而撞色的两门课如果恰好挨着，会让人以为是同一门课。统一分配能保证
/// 「这一屏能看到的课」两两不同色（课数超过调色板才会重复）。
/// 用户手动指定过 `color` 的课不参与分配，也不会被别的课抢走。
Map<String, Color> assignCourseColors(Iterable<Course> courses) {
  final result = <String, Color>{};
  final taken = <Color>{};
  final pending = <Course>[];

  for (final course in courses) {
    if (result.containsKey(course.title)) continue;
    final hex = course.color;
    if (hex != null && hex.isNotEmpty) {
      final color = colorFromHex(hex);
      result[course.title] = color;
      taken.add(color);
    } else {
      pending.add(course);
    }
  }

  for (final course in pending) {
    var index = _stableHash(course.title) % coursePalette.length;
    for (var step = 0; step < coursePalette.length; step++) {
      final candidate = coursePalette[(index + step) % coursePalette.length];
      if (!taken.contains(candidate)) {
        taken.add(candidate);
        result[course.title] = candidate;
        break;
      }
    }
    result.putIfAbsent(
      course.title,
      () => coursePalette[index], // 色用光了，允许重复
    );
  }
  return result;
}

class TimelineItem extends StatelessWidget {
  const TimelineItem({
    super.key,
    required this.entry,
    this.onToggleTask,
    this.onTap,
    this.courseColors,
  });

  final TimelineEntry entry;
  final ValueChanged<TimelineEntry>? onToggleTask;
  final ValueChanged<TimelineEntry>? onTap;

  /// 课名 → 底色，由页面用 [assignCourseColors] 算好传进来。
  ///
  /// 必须和课表页共用同一份分配结果，不然同一门课在两页会显示成两种颜色
  /// （2026-11-22 用户要求「日程的条目颜色要和课表一样」）。
  final Map<String, Color>? courseColors;

  @override
  Widget build(BuildContext context) {
    // 以前这里是 colorFromHex(entry.colorHex)，没设色的课一律回落到默认蓝，
    // 于是日程页满屏一样的蓝条、跟课表的花色对不上。
    final color = courseColors?[entry.title] ?? courseColorFor(entry);
    final isTask = entry.type == EntryType.task;
    final location = displayLocation(entry.location);
    // 有优先级时左侧色条跟着变，扫一眼就能挑出要紧的那几条。
    final barColor = entry.isImportant ? priorityColor(entry.priority) : color;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      // 课程卡带一层课表同款淡色，和左边色条呼应；事件/任务不加底色，
      // 免得整屏糊成一片。
      //
      // 必须用 alphaBlend 先跟白底混成**不透明**色。直接给带 alpha 的颜色
      // （哪怕 alpha 只有 30）卡片等于半透明，自己的阴影会从底下透上来，
      // 淡粉淡绿全变成一片灰紫——真机截图一眼就看得出来。
      color: entry.type == EntryType.course
          ? Color.alphaBlend(color.withAlpha(46), ivoryBackground)
          : null,
      // Material 3 的 Card 会再叠一层 surfaceTint（主题紫），这里关掉。
      surfaceTintColor: Colors.transparent,
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
                width: 5,
                height: 44,
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: BorderRadius.circular(3),
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
            if (location.isNotEmpty) location,
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
