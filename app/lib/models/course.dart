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
    this.note,
    this.teacher,
    this.weeks,
    required this.semesterStart, // yyyy-MM-dd
    required this.semesterEnd,
    this.weekParity = 0, // 0=每周，1=单周，2=双周（weeks 为空时兜底）
  });

  final int? id;
  final String title;
  final int dayOfWeek;
  final String startTime;
  final String endTime;
  final String? location;
  final String? color;
  final String? note;

  /// 任课教师。
  final String? teacher;

  /// 上课周次，如 `3-18`、`4,6,8,10`、`3-12,15-18`。null/空 = 用 [weekParity]。
  ///
  /// 真实课表的周次是任意集合（偶数周但从第 4 周起、跳过某几周），
  /// 「单/双周」表达不了，所以单存一份写法，解析交给 `WeekSet`。
  final String? weeks;

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
    'note': note,
    'teacher': teacher,
    'weeks': weeks,
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
    note: map['note'] as String?,
    teacher: map['teacher'] as String?,
    weeks: map['weeks'] as String?,
    semesterStart: map['semester_start']! as String,
    semesterEnd: map['semester_end']! as String,
    weekParity: (map['week_parity'] as num?)?.toInt() ?? 0,
  );
}
