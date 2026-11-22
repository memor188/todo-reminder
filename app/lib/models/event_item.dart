/// 事件型待办：绝对时刻，到点人必须在那（考试、讲座）。
class EventItem {
  const EventItem({
    this.id,
    required this.title,
    required this.startAt, // ISO 8601，例如 2026-11-21T17:00:00
    this.location,
    this.note,
    this.done = false,
    this.remindBeforeMinutes = 0,
    this.priority = 0,
  });

  final int? id;
  final String title;
  final String startAt;
  final String? location;
  final String? note;
  final bool done;

  /// 提前多少分钟提醒。0 = 到点提醒。
  final int remindBeforeMinutes;

  /// 优先级：0 普通 / 1 重要 / 2 紧急。
  /// 常量定义在 timeline.dart，这里写字面量是为了不让模型层反过来依赖显示层。
  final int priority;

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'start_at': startAt,
    'location': location,
    'note': note,
    'done': done ? 1 : 0,
    'remind_before_minutes': remindBeforeMinutes,
    'priority': priority,
  };

  /// 老数据 / 老备份没有这一列，缺字段时按 0（普通）处理。
  factory EventItem.fromMap(Map<String, Object?> map) => EventItem(
    id: map['id'] as int?,
    title: map['title']! as String,
    startAt: map['start_at']! as String,
    location: map['location'] as String?,
    note: map['note'] as String?,
    done: (map['done'] as num?)?.toInt() == 1,
    remindBeforeMinutes:
        (map['remind_before_minutes'] as num?)?.toInt() ?? 0,
    priority: (map['priority'] as num?)?.toInt() ?? 0,
  );
}
