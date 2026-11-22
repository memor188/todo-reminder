import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/models/period_table.dart';
import 'package:todo_app/services/settings_service.dart';

/// 节次 → 钟点 的换算。这是课表导入正确性的地基：
/// AI 只会输出「第 3-5 节」，换算错了整张课表的时间都跟着错。
void main() {
  const table = PeriodTable.shantouDefault;

  group('汕大默认作息表', () {
    test('13 个小节，顺序与官方作息表一致', () {
      expect(
        table.slots.map((s) => s.label).toList(),
        ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 'A', 'B', 'C'],
      );
    });

    test('首末两节时间对得上', () {
      expect(table.byLabel('1')!.start, '08:00');
      expect(table.byLabel('1')!.end, '08:45');
      expect(table.byLabel('C')!.start, '21:10');
      expect(table.byLabel('C')!.end, '21:55');
    });

    test('晚上三节用 A/B/C 而不是 10/11/12', () {
      expect(table.byLabel('A'), isNotNull);
      expect(table.byLabel('B'), isNotNull);
      expect(table.byLabel('C'), isNotNull);
      expect(table.byLabel('10'), isNull);
      expect(table.byLabel('11'), isNull);
    });

    test('每节都是 45 分钟', () {
      for (final slot in table.slots) {
        final start = _minutes(slot.start);
        final end = _minutes(slot.end);
        expect(end - start, 45, reason: '第 ${slot.label} 节不是 45 分钟');
      }
    });
  });

  group('节次写法换算', () {
    test('"345" = 第 3~5 节（10:00–12:35）', () {
      final span = table.resolveSpec('345')!;
      expect(span.labels, ['3', '4', '5']);
      expect(span.start, '10:00');
      expect(span.end, '12:35');
    });

    test('"12" = 第 1~2 节（08:00–09:40）', () {
      final span = table.resolveSpec('12')!;
      expect(span.labels, ['1', '2']);
      expect(span.start, '08:00');
      expect(span.end, '09:40');
    });

    test('"3-5" 与 "第3-5节" 与 "345" 等价', () {
      for (final spec in ['345', '3-5', '第3-5节', '3~5', '3到5']) {
        final span = table.resolveSpec(spec);
        expect(span, isNotNull, reason: spec);
        expect([span!.start, span.end], ['10:00', '12:35'], reason: spec);
      }
    });

    test('全角数字也能认', () {
      final span = table.resolveSpec('３-５')!;
      expect(span.labels, ['3', '4', '5']);
    });

    test('"AB" = 晚上 A~B 节（19:20–21:00）', () {
      final span = table.resolveSpec('AB')!;
      expect(span.labels, ['A', 'B']);
      expect(span.start, '19:20');
      expect(span.end, '21:00');
    });

    test('小写 "ab" 也认', () {
      final span = table.resolveSpec('ab')!;
      expect(span.labels, ['A', 'B']);
    });

    test('单节 "9" 只占自己那 45 分钟', () {
      final span = table.resolveSpec('9')!;
      expect(span.labels, ['9']);
      expect(span.start, '16:55');
      expect(span.end, '17:40');
    });

    test('"0" 是第 10 节（17:50–18:35），不是空值', () {
      final span = table.resolveSpec('0')!;
      expect(span.labels, ['0']);
      expect(span.start, '17:50');
      expect(span.end, '18:35');
    });

    test('"10" 拆成第 1 节与第 0 节，跨度 08:00–18:35', () {
      // 汕大用 0 表示第 10 节，不存在「第十节」这个标签，所以逐字符拆是对的。
      final span = table.resolveSpec('10')!;
      expect(span.labels.first, '1');
      expect(span.labels.last, '0');
      expect(span.start, '08:00');
      expect(span.end, '18:35');
    });

    test('逆序 "21" 仍按课时先后取，不被输入顺序带偏', () {
      final span = table.resolveSpec('21')!;
      expect(span.labels, ['1', '2']);
      expect(span.start, '08:00');
      expect(span.end, '09:40');
    });

    test('跨大节的 "3-7" 直接取首尾', () {
      final span = table.resolveSpec('3-7')!;
      expect(span.start, '10:00');
      expect(span.end, '15:40');
    });
  });

  group('认不出来时返回 null，不瞎猜', () {
    test('空串', () {
      expect(table.resolveSpec(''), isNull);
      expect(table.resolveSpec('   '), isNull);
    });

    test('作息表里没有的节次字母', () {
      expect(table.resolveSpec('D'), isNull);
      expect(table.resolveSpec('A-D'), isNull);
    });

    test('混入非节次字符', () {
      expect(table.resolveSpec('3-5节(理论)'), isNull);
    });

    test('范围写成三段', () {
      expect(table.resolveSpec('1-3-5'), isNull);
    });

    test('只有连接符', () {
      expect(table.resolveSpec('-'), isNull);
    });
  });

  group('存储往返', () {
    test('toJson → fromJson 保持节次与时间', () {
      final restored = PeriodTable.fromJson(table.toJson())!;
      expect(restored.slots.length, 13);
      expect(restored.byLabel('4')!.start, '10:55');
    });

    test('脏数据被丢弃，全脏时返回 null', () {
      final restored = PeriodTable.fromJson([
        {'label': '1', 'start': '08:00', 'end': '08:45'},
        {'label': '', 'start': '09:00', 'end': '09:45'}, // 空标签
        {'label': '3', 'start': '10:00', 'end': '09:00'}, // 结束早于开始
        {'label': '4', 'start': '乱写', 'end': '11:40'}, // 时间解析不出
      ])!;
      expect(restored.slots.map((s) => s.label).toList(), ['1']);

      expect(PeriodTable.fromJson(<Object?>[]), isNull);
      expect(PeriodTable.fromJson('不是列表'), isNull);
    });

    test('自定义作息表能覆盖默认值（换了学校也照用）', () {
      final custom = PeriodTable([
        PeriodSlot(label: '1', start: '08:20', end: '09:05'),
        PeriodSlot(label: '2', start: '09:15', end: '10:00'),
      ]);
      final span = custom.resolveSpec('12')!;
      expect(span.start, '08:20');
      expect(span.end, '10:00');
    });
  });

  group('设置服务回落', () {
    test('没存过时给汕大默认表', () {
      final settings = SettingsService.inMemory();
      expect(settings.periodTable.slots.length, 13);
      expect(settings.periodTable.byLabel('1')!.start, '08:00');
    });

    test('存过之后读回自定义值', () async {
      final settings = SettingsService.inMemory();
      await settings.savePeriodTable(
        const PeriodTable([
          PeriodSlot(label: '1', start: '07:30', end: '08:15'),
        ]),
      );
      expect(settings.periodTable.byLabel('1')!.start, '07:30');
      expect(settings.periodTable.slots.length, 1);
    });
  });
}

int _minutes(String hm) {
  final parts = hm.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}
