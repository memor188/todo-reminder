/// 事件型待办：绝对时刻，到点人必须在那（考试、讲座）。
class EventItem {
  const EventItem({
    this.id,
    required this.title,
    required this.startAt, // ISO 8601，例如 2026-11-21T17:00:00
    this.location,
    this.note,
    this.done = false,
  });

  final int? id;
  final String title;
  final String startAt;
  final String? location;
  final String? note;
  final bool done;

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'start_at': startAt,
    'location': location,
    'note': note,
    'done': done ? 1 : 0,
  };

  factory EventItem.fromMap(Map<String, Object?> map) => EventItem(
    id: map['id'] as int?,
    title: map['title']! as String,
    startAt: map['start_at']! as String,
    location: map['location'] as String?,
    note: map['note'] as String?,
    done: (map['done'] as num?)?.toInt() == 1,
  );
}
