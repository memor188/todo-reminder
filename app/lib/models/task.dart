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
  });

  final int? id;
  final String title;
  final String dueDate;
  final String? dueTime;
  final String? location;
  final String? note;
  final bool done;

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'due_date': dueDate,
    'due_time': dueTime,
    'location': location,
    'note': note,
    'done': done ? 1 : 0,
  };

  factory TaskItem.fromMap(Map<String, Object?> map) => TaskItem(
    id: map['id'] as int?,
    title: map['title']! as String,
    dueDate: map['due_date']! as String,
    dueTime: map['due_time'] as String?,
    location: map['location'] as String?,
    note: map['note'] as String?,
    done: (map['done'] as num?)?.toInt() == 1,
  );
}
