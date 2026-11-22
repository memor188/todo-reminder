import 'timeline.dart';

/// 一节课在作息表里的位置（如「第 3 节 10:00–10:45」）。
class PeriodSlot {
  const PeriodSlot({
    required this.label,
    required this.start,
    required this.end,
  });

  /// 小节标签：汕大是 '1'–'9'、'0'（第 10 节）、'A'/'B'/'C'（晚上三节）。
  final String label;
  final String start; // HH:mm
  final String end; // HH:mm

  Map<String, Object?> toMap() => {
    'label': label,
    'start': start,
    'end': end,
  };

  /// 脏数据返回 null（时间解析不出、或结束不晚于开始）。
  static PeriodSlot? fromMap(Map<String, Object?> map) {
    final label = map['label'];
    final start = map['start'];
    final end = map['end'];
    if (label is! String || label.trim().isEmpty) return null;
    if (start is! String || end is! String) return null;
    final s = tryParseHm(start);
    final e = tryParseHm(end);
    if (s == null || e == null || e <= s) return null;
    return PeriodSlot(label: label.trim(), start: start, end: end);
  }
}

/// 一段节次换算出来的起止时间。
class PeriodSpan {
  const PeriodSpan({
    required this.labels,
    required this.start,
    required this.end,
  });

  final List<String> labels;
  final String start;
  final String end;
}

/// 作息表：把课表里的「第几节」换算成钟点。
///
/// 为什么要这张表：课表原文几乎不写钟点，写的是「第 3-4 节」「345」。
/// 每个学校的节次时间都不一样，AI 不可能知道，只能由 App 按本地作息表换算。
class PeriodTable {
  const PeriodTable(this.slots);

  final List<PeriodSlot> slots;

  /// 汕头大学作息（2017 年春季学期起执行，每节 45 分钟）。
  ///
  /// 用户 2026-11-22 提供的官方作息表，注意：下午第 10 节标作「0 节」，
  /// 晚上三节标作 A/B/C。大节对应关系：一=1-2、二=3-5、三=6-7、四=8-0、五=A-C。
  static const PeriodTable shantouDefault = PeriodTable([
    // 上午（大节一、二）
    PeriodSlot(label: '1', start: '08:00', end: '08:45'),
    PeriodSlot(label: '2', start: '08:55', end: '09:40'),
    PeriodSlot(label: '3', start: '10:00', end: '10:45'),
    PeriodSlot(label: '4', start: '10:55', end: '11:40'),
    PeriodSlot(label: '5', start: '11:50', end: '12:35'),
    // 下午（大节三、四）
    PeriodSlot(label: '6', start: '14:00', end: '14:45'),
    PeriodSlot(label: '7', start: '14:55', end: '15:40'),
    PeriodSlot(label: '8', start: '16:00', end: '16:45'),
    PeriodSlot(label: '9', start: '16:55', end: '17:40'),
    PeriodSlot(label: '0', start: '17:50', end: '18:35'),
    // 晚上（大节五）
    PeriodSlot(label: 'A', start: '19:20', end: '20:05'),
    PeriodSlot(label: 'B', start: '20:15', end: '21:00'),
    PeriodSlot(label: 'C', start: '21:10', end: '21:55'),
  ]);

  /// 大节 → 小节的对应，只用于喂给 AI 的提示词，代码逻辑不依赖它。
  static const Map<String, String> bigSectionHint = {
    '一': '1-2',
    '二': '3-5',
    '三': '6-7',
    '四': '8-0',
    '五': 'A-C',
  };

  bool get isEmpty => slots.isEmpty;

  PeriodSlot? byLabel(String label) {
    final key = label.trim().toUpperCase();
    for (final slot in slots) {
      if (slot.label.toUpperCase() == key) return slot;
    }
    return null;
  }

  /// 把课表里的节次写法换算成起止时间。
  ///
  /// 支持的写法（汕大课表用例）：
  /// - `345` / `3-5` / `第3-5节` → 第 3~5 节
  /// - `12` → 第 1~2 节
  /// - `AB` / `A-C` → 晚上 A~C 节
  /// - `9` → 第 9 节
  ///
  /// 认不出来（含作息表里没有的节次）返回 null，由调用方提示用户核对作息表。
  /// 注意 `10` 会被拆成第 1 节与第 0 节——汕大没有「第 10 节」，用 0 表示，
  /// 所以逐字符拆是正确读法；若将来作息表里真加了 `10` 标签，`byLabel`
  /// 会先命中整串，不会被拆开。
  PeriodSpan? resolveSpec(String spec) {
    final cleaned = _normalizeSpec(spec);
    if (cleaned.isEmpty) return null;

    if (cleaned.contains('-')) {
      final parts = cleaned.split('-');
      if (parts.length != 2) return null;
      if (parts[0].isEmpty || parts[1].isEmpty) return null;
      return _spanOf([parts[0], parts[1]]);
    }

    if (byLabel(cleaned) != null) return _spanOf([cleaned]);
    return _spanOf(cleaned.split(''));
  }

  /// 按「第 n 节」的序号取跨度（n 从 1 起，对应作息表第 n 行）。
  ///
  /// 教务系统导出的 .xls 用的是 `01`、`03-04-05`、`11-12-13` 这种编号，
  /// 和标签 `1..9 / 0 / A / B / C` 不是一套写法（第 10 节写作 0，晚上写作 A/B/C），
  /// 只能按顺序对：第 11 个 = 作息表第 11 行的标签 `A`。
  /// 超出作息表行数返回 null，由调用方提示用户补作息表。
  PeriodSpan? spanByNumbers(Iterable<int> numbers) {
    final indexes = <int>[];
    for (final n in numbers) {
      final index = n - 1;
      if (index < 0 || index >= slots.length) return null;
      indexes.add(index);
    }
    if (indexes.isEmpty) return null;
    indexes.sort();
    return PeriodSpan(
      labels: [
        for (var i = indexes.first; i <= indexes.last; i++) slots[i].label,
      ],
      start: slots[indexes.first].start,
      end: slots[indexes.last].end,
    );
  }

  /// 从若干标签里取「最靠前那节的开始」到「最靠后那节的结束」。
  PeriodSpan? _spanOf(List<String> labels) {
    final indexes = <int>[];
    for (final label in labels) {
      final index = slots.indexWhere(
        (slot) => slot.label.toUpperCase() == label.toUpperCase(),
      );
      if (index < 0) return null;
      indexes.add(index);
    }
    if (indexes.isEmpty) return null;
    indexes.sort();
    return PeriodSpan(
      labels: [
        for (var i = indexes.first; i <= indexes.last; i++) slots[i].label,
      ],
      start: slots[indexes.first].start,
      end: slots[indexes.last].end,
    );
  }

  /// 归一化：全角数字转半角、各种波浪/长横统一成 '-'、去掉「第/节/小」等杂字。
  static String _normalizeSpec(String input) {
    final buffer = StringBuffer();
    for (final rune in input.trim().runes) {
      if (rune >= 0xFF10 && rune <= 0xFF19) {
        buffer.writeCharCode(rune - 0xFEE0);
      } else if (rune == 0xFF0D ||
          rune == 0x2014 ||
          rune == 0x2013 ||
          rune == 0xFF5E ||
          rune == 0x007E) {
        buffer.write('-');
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer
        .toString()
        .toUpperCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('第', '')
        .replaceAll('小节', '')
        .replaceAll('节', '')
        .replaceAll('到', '-')
        .replaceAll('至', '-')
        .replaceAll('、', '-')
        .replaceAll(',', '-');
  }

  List<Map<String, Object?>> toJson() =>
      slots.map((slot) => slot.toMap()).toList();

  /// 存坏了返回 null（调用方回落到默认作息表），不让一条脏数据拖垮导入。
  static PeriodTable? fromJson(Object? raw) {
    if (raw is! List) return null;
    final parsed = <PeriodSlot>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final slot = PeriodSlot.fromMap(item.cast<String, Object?>());
      if (slot != null) parsed.add(slot);
    }
    if (parsed.isEmpty) return null;
    return PeriodTable(parsed);
  }
}
