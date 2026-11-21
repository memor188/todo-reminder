/// 课程：周期规则，改一次等于改整个学期。
class Course {
  const Course({
    this.id,
    required this.title,
    required this.dayOfWeek, // 1=周一 ... 7=周日
    required this.startTime, // HH:mm
    required this.endTime,
    this.location,
    this.color,
    required this.semesterStart, // yyyy-MM-dd
    required this.semesterEnd,
    this.weekParity = 0, // 0=每周，1=单周，2=双周（V2 使用）
  });

  final int? id;
  final String title;
  final int dayOfWeek;
  final String startTime;
  final String endTime;
  final String? location;
  final String? color;
  final String semesterStart;
  final String semesterEnd;
  final int weekParity;

  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'day_of_week': dayOfWeek,
    'start_time': startTime,
    'end_time': endTime,
    'location': location,
    'color': color,
    'semester_start': semesterStart,
    'semester_end': semesterEnd,
    'week_parity': weekParity,
  };

  factory Course.fromMap(Map<String, Object?> map) => Course(
    id: map['id'] as int?,
    title: map['title']! as String,
    dayOfWeek: (map['day_of_week'] as num).toInt(),
    startTime: map['start_time']! as String,
    endTime: map['end_time']! as String,
    location: map['location'] as String?,
    color: map['color'] as String?,
    semesterStart: map['semester_start']! as String,
    semesterEnd: map['semester_end']! as String,
    weekParity: (map['week_parity'] as num?)?.toInt() ?? 0,
  );
}
