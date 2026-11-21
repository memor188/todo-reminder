/// 学期方案：把「本学期从哪天到哪天」存成可复用的一组日期。
///
/// 2026-11-21 用户提出：学期起止每学期只变一次，却每次新建课程都要重打一遍。
/// 这里允许存多套（2026秋 / 2027春 …），新建课程时一键套用。
///
/// 注意：学期起止不只是摆设，单双周靠它算第几周
/// （`day.difference(semesterStart).inDays ~/ 7 + 1`），套错方案会让课排到错误的周。
class SemesterPlan {
  const SemesterPlan({
    required this.id,
    required this.name,
    required this.start,
    required this.end,
  });

  /// 本地唯一标识，用创建时刻的毫秒数即可（不做云同步，无需全局唯一）。
  final String id;

  /// 显示名，如「2026秋」。
  final String name;

  /// 学期开始，yyyy-MM-dd。
  final String start;

  /// 学期结束，yyyy-MM-dd。
  final String end;

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'start': start,
    'end': end,
  };

  static SemesterPlan? fromMap(Map<String, dynamic> map) {
    final id = map['id']?.toString();
    final name = map['name']?.toString();
    final start = map['start']?.toString();
    final end = map['end']?.toString();
    if (id == null || name == null || start == null || end == null) return null;
    if (DateTime.tryParse(start) == null || DateTime.tryParse(end) == null) {
      return null;
    }
    return SemesterPlan(id: id, name: name, start: start, end: end);
  }

  SemesterPlan copyWith({String? name, String? start, String? end}) =>
      SemesterPlan(
        id: id,
        name: name ?? this.name,
        start: start ?? this.start,
        end: end ?? this.end,
      );

  /// 日期是否落在本学期内（含首尾两天，按天比较，忽略钟点）。
  bool contains(DateTime date) {
    final from = DateTime.tryParse(start);
    final to = DateTime.tryParse(end);
    if (from == null || to == null) return false;
    final day = DateTime(date.year, date.month, date.day);
    final first = DateTime(from.year, from.month, from.day);
    final last = DateTime(to.year, to.month, to.day);
    return !day.isBefore(first) && !day.isAfter(last);
  }

  /// 挑出当前日期所属的方案。
  ///
  /// 方案允许重叠（有人会把「2026秋」和「2026-2027学年」都存着），
  /// 重叠时取开始日更晚的那个——范围更窄，通常才是用户此刻真实在上的学期。
  static SemesterPlan? pickForDate(
    Iterable<SemesterPlan> plans,
    DateTime date,
  ) {
    SemesterPlan? best;
    DateTime? bestStart;
    for (final plan in plans) {
      if (!plan.contains(date)) continue;
      final start = DateTime.tryParse(plan.start);
      if (start == null) continue;
      if (bestStart == null || start.isAfter(bestStart)) {
        best = plan;
        bestStart = start;
      }
    }
    return best;
  }
}
