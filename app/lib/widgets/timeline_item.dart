import 'package:flutter/material.dart';

import '../models/course.dart';
import '../models/timeline.dart';
import '../theme.dart';
import 'disintegrate/index.dart';

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
    this.state = EntryState.normal,
    this.flash = false,
    this.dissolveProgress,
    this.dissolveDrift = const Offset(18, 56),
    this.dissolveSeed = 0,
  });

  final TimelineEntry entry;
  final ValueChanged<TimelineEntry>? onToggleTask;
  final ValueChanged<TimelineEntry>? onTap;

  /// 课名 → 底色，由页面用 [assignCourseColors] 算好传进来。
  ///
  /// 必须和课表页共用同一份分配结果，不然同一门课在两页会显示成两种颜色
  /// （2026-11-22 用户要求「日程的条目颜色要和课表一样」）。
  final Map<String, Color>? courseColors;

  /// 三态（2026-11-25）：正常原色、过期灰+淡红条、完成灰+勾+删除线。
  final EntryState state;

  /// 刚落位时闪一下，让人看见它去了哪。
  final bool flash;

  /// 勾选时的粉尘消散进度（2026-11-26 改用 GPU shader）。
  ///
  /// null = 不播效果，普通卡片；0 = 完好；1 = 全部化成粉尘飞走。
  /// 由 [DayTimelineList] 的四阶段状态机驱动：源条目 0→1 散开，目标条目
  /// 1→0 在下方聚拢。shader 让**卡片本身**碎成粉尘（不是另画一层粒子），
  /// 所以有值时卡片本体的淡入淡出由 DisintegrateEffect 全权负责。
  final double? dissolveProgress;

  /// 粉尘飞散方向（逻辑像素）。散开和重组必须用同一个值，才能"往哪散、
  /// 就从哪聚回来"。默认往右下——配合下方重组区的方位。
  final Offset dissolveDrift;

  /// 粒子分布种子，同一条散开/重组要一致才像同一批粉尘。
  final double dissolveSeed;

  @override
  Widget build(BuildContext context) {
    // 以前这里是 colorFromHex(entry.colorHex)，没设色的课一律回落到默认蓝，
    // 于是日程页满屏一样的蓝条、跟课表的花色对不上。
    final color = courseColors?[entry.title] ?? courseColorFor(entry);
    final isCourse = entry.type == EntryType.course;
    final isOverdue = state == EntryState.overdue;
    final isDone = state == EntryState.done;
    final dimmed = isOverdue || isDone;
    final location = displayLocation(entry.location);

    // 过期用淡红、完成用中性灰，正常时才让课程/优先级决定颜色。
    // 三种灰要能分开：过期是「欠着」，完成是「了了」，语义不同。
    final Color barColor;
    if (isDone) {
      barColor = const Color(0xFFBDBDBD);
    } else if (isOverdue) {
      barColor = const Color(0xFFE57373);
    } else {
      barColor = entry.isImportant ? priorityColor(entry.priority) : color;
    }

    final card = Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      // 课程卡带一层课表同款淡色，和左边色条呼应；事件/任务不加底色，
      // 免得整屏糊成一片。
      //
      // 必须用 alphaBlend 先跟白底混成**不透明**色。直接给带 alpha 的颜色
      // （哪怕 alpha 只有 30）卡片等于半透明，自己的阴影会从底下透上来，
      // 淡粉淡绿全变成一片灰紫——真机截图一眼就看得出来。
      color: dimmed
          ? null
          : (isCourse
                ? Color.alphaBlend(color.withAlpha(46), ivoryBackground)
                : null),
      // Material 3 的 Card 会再叠一层 surfaceTint（主题紫），这里关掉。
      surfaceTintColor: Colors.transparent,
      child: ListTile(
        onTap: onTap == null ? null : () => onTap!(entry),
        // 课程不能勾（上完就是上完，没有「完成」这个动作）；
        // 事件和任务都能勾 —— 2026-11-25 之前事件是没有入口的。
        leading: isCourse
            ? Container(
                width: 5,
                height: 44,
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: BorderRadius.circular(3),
                ),
              )
            : IconButton(
                key: Key('toggle_${entry.key}'),
                icon: Icon(
                  isDone
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                ),
                color: isDone ? const Color(0xFF9E9E9E) : Colors.grey.shade700,
                onPressed: () => onToggleTask?.call(entry),
              ),
        title: Text(
          entry.title,
          style: TextStyle(
            decoration: isDone ? TextDecoration.lineThrough : null,
            color: dimmed ? const Color(0xFF9E9E9E) : null,
          ),
        ),
        subtitle: Text(
          [
            entry.timeLabel,
            if (location.isNotEmpty) location,
          ].join('  ·  '),
          style: TextStyle(color: dimmed ? const Color(0xFFBDBDBD) : null),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry.isImportant && !dimmed) ...[
              _PriorityTag(priority: entry.priority),
              const SizedBox(width: 6),
            ],
            Text(
              isDone
                  ? '已完成'
                  : (isOverdue
                        ? '已过期'
                        : switch (entry.type) {
                            EntryType.course => '课程',
                            EntryType.event => '事件',
                            EntryType.task => '任务',
                          }),
              style: TextStyle(
                fontSize: 12,
                color: dimmed ? const Color(0xFFBDBDBD) : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );

    // 粉尘消散：shader 把卡片本身拆成颗粒，卡片淡入淡出由它全权负责，
    // 这里传进去的是原样卡片，不额外套 Opacity（避免叠两层透明度）。
    //
    // 参数照着官方 demo 的"极细粉尘"调：particleSize 1.2（细粉不是碎块）、
    // sweep 0.4（从一侧扫过去，不是整张一起淡）、turbulence/scatter 给粉尘
    // 各自的方向和游走，才不会是"带洞的平移"。
    Widget body = dissolveProgress == null
        ? card
        : DisintegrateEffect(
            key: Key('dissolve_${entry.key}'),
            progress: dissolveProgress!.clamp(0.0, 1.0),
            drift: dissolveDrift,
            particleSize: 1.2,
            sweep: 0.4,
            turbulence: 28,
            scatter: 1.5,
            seed: dissolveSeed,
            // spread 必须是 zero：它是 EdgeInsets，会占布局空间。源行套上
            // shader 时若多出 padding，高度凭空变大、下方条目被顶下去，
            // 违背"散开阶段下方纹丝不动"。粉尘因此限制在卡片自身矩形内，
            // 碎裂质感仍在，只是飞散不出卡片边界。
            spread: EdgeInsets.zero,
            child: card,
          );

    if (!flash) return body;

    // 落位高亮：400ms 内从淡黄褪到透明。跨区跳跃时唯一能让人看见的线索。
    //
    // 终点色必须是「同一个淡黄的全透明版」0x00FFF1C2，不能用
    // Colors.transparent（那是透明黑 0x00000000）——lerp 会连 RGB 一起拉到黑，
    // 中途变成半透明深褐，真机上看见的是一块脏灰褐色，不是淡黄光。
    // 2026-11-25 真机验收实测：错误写法在 t≈0.5 时出 #C4C0B4。
    //
    // flash 放在 body 外层：有粒子时它是「聚拢完成之后的临门一脚」，
    // 顺序上不会和粒子淡入打架。
    return TweenAnimationBuilder<double>(
      key: Key('flash_${entry.key}'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 400),
      builder: (context, t, child) => ColoredBox(
        color: Color.lerp(const Color(0xFFFFF1C2), const Color(0x00FFF1C2), t)!,
        child: child,
      ),
      child: body,
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
