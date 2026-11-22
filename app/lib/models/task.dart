/// 任务型待办：当天做完即可，时刻可空（取快递、写作业）。
class TaskItem {
  const TaskItem({
    this.id,
    required this.title,
    required this.dueDate, // yyyy-MM-dd
    this.dueTime, // HH:mm，可空
    this.location,
    this.note,
    this.done = false,
    this.remindBeforeMinutes = 0,
  });

  final int? id;
  final String title;
  final String dueDate;
  final String? dueTime;
  final String? location;
  final String? note;
  final bool done;

  /// 提前多少分钟提醒。0 = 到点提醒。
  final int remindBeforeMinutes;

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'due_date': dueDate,
    'due_time': dueTime,
    'location': location,
    'note': note,
    'done': done ? 1 : 0,
    'remind_before_minutes': remindBeforeMinutes,
  };

  /// 老数据 / 老备份没有这一列，缺字段时按 0（到点）处理。
  factory TaskItem.fromMap(Map<String, Object?> map) => TaskItem(
    id: map['id'] as int?,
    title: map['title']! as String,
    dueDate: map['due_date']! as String,
    dueTime: map['due_time'] as String?,
    location: map['location'] as String?,
    note: map['note'] as String?,
    done: (map['done'] as num?)?.toInt() == 1,
    remindBeforeMinutes:
        (map['remind_before_minutes'] as num?)?.toInt() ?? 0,
  );
}
