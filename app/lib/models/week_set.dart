/// 上课周次集合。
///
/// 为什么不用「单双周」：真实课表里是 `4,6,8,10,12,14,16,18`（偶数周但从第 4 周起）、
/// `3-12,15-18`（跳过 13-14 周）、`3,5-11` 这类写法，「单/双」根本表达不了。
/// 所以直接存周次集合，兼容所有写法。
class WeekSet {
  const WeekSet(this.weeks);

  /// 允许的最大周次。一学期不会超过 30 周，超出的当作脏数据丢掉。
  static const int maxWeek = 30;

  final Set<int> weeks;

  bool get isEmpty => weeks.isEmpty;

  bool contains(int week) => weeks.contains(week);

  /// 解析 `3-18`、`4,6,8`、`3-12,15-18`、`3,5-11`、`第3-16周` 这些写法。
  ///
  /// 认不出来（含「单/双」这类文字）返回 null，交给调用方回落到旧的 weekParity——
  /// **不猜**，猜错就是整学期少上一门课。
  static WeekSet? tryParse(String? spec) {
    if (spec == null) return null;
    var text = spec.trim();
    if (text.isEmpty) return null;
    // 去掉中文外壳：第 3-16 周 / 3-16周 / [周]
    text = text
        .replaceAll(RegExp(r'[\[\]()（）]'), ' ')
        .replaceAll('第', '')
        .replaceAll('周', '')
        .replaceAll('，', ',')
        .replaceAll('、', ',')
        .replaceAll('到', '-')
        .replaceAll('至', '-')
        .replaceAll('~', '-')
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll(' ', '');
    if (text.isEmpty) return null;
    // 「单周」「双周」「1-16单周」这类文字写法这里不处理
    if (RegExp(r'[单双奇偶]').hasMatch(text)) return null;

    final weeks = <int>{};
    for (final part in text.split(',')) {
      if (part.isEmpty) continue;
      final dash = part.indexOf('-');
      if (dash < 0) {
        final value = int.tryParse(part);
        if (value == null) return null;
        if (value >= 1 && value <= maxWeek) weeks.add(value);
        continue;
      }
      final from = int.tryParse(part.substring(0, dash));
      final to = int.tryParse(part.substring(dash + 1));
      if (from == null || to == null) return null;
      final lo = from <= to ? from : to;
      final hi = from <= to ? to : from;
      for (var i = lo; i <= hi; i++) {
        if (i >= 1 && i <= maxWeek) weeks.add(i);
      }
    }
    if (weeks.isEmpty) return null;
    return WeekSet(weeks);
  }

  /// 把周次集合压回紧凑写法：连续的 3 周以上合成 `a-b`，零散的单独列。
  ///
  /// 3-18 → `3-18`；4,6,8 → `4,6,8`；3,4,5,7 → `3-5,7`
  static String format(Iterable<int> input) {
    final sorted = input.where((w) => w >= 1 && w <= maxWeek).toSet().toList()
      ..sort();
    if (sorted.isEmpty) return '';
    final parts = <String>[];
    var runStart = sorted.first;
    var prev = sorted.first;
    void flush() {
      if (prev - runStart >= 2) {
        parts.add('$runStart-$prev');
      } else {
        for (var w = runStart; w <= prev; w++) {
          parts.add('$w');
        }
      }
    }

    for (var i = 1; i < sorted.length; i++) {
      final current = sorted[i];
      if (current == prev + 1) {
        prev = current;
        continue;
      }
      flush();
      runStart = current;
      prev = current;
    }
    flush();
    return parts.join(',');
  }

  /// 多段周次取并集后压成字符串（同一门课被拆成几块时用）。
  static String unionToSpec(Iterable<String> specs) {
    final weeks = <int>{};
    for (final spec in specs) {
      final parsed = tryParse(spec);
      if (parsed != null) weeks.addAll(parsed.weeks);
    }
    return format(weeks);
  }

  /// 相邻周次是否连续（用于把碎片化的周次压成范围）。
  static bool isContiguous(Iterable<int> weeks) {
    final sorted = weeks.toSet().toList()..sort();
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i] != sorted[i - 1] + 1) return false;
    }
    return sorted.isNotEmpty;
  }
}
