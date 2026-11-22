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
  });

  final int? id;
  final String title;
  final String startAt;
  final String? location;
  final String? note;
  final bool done;

  /// 提前多少分钟提醒。0 = 到点提醒。
  final int remindBeforeMinutes;

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'start_at': startAt,
    'location': location,
    'note': note,
    'done': done ? 1 : 0,
    'remind_before_minutes': remindBeforeMinutes,
  };

  /// 老数据 / 老备份没有这一列，缺字段时按 0（到点）处理。
  factory EventItem.fromMap(Map<String, Object?> map) => EventItem(
    id: map['id'] as int?,
    title: map['title']! as String,
    startAt: map['start_at']! as String,
    location: map['location'] as String?,
    note: map['note'] as String?,
    done: (map['done'] as num?)?.toInt() == 1,
    remindBeforeMinutes:
        (map['remind_before_minutes'] as num?)?.toInt() ?? 0,
  );
}
