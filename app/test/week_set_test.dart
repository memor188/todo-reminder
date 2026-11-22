import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/models/week_set.dart';

/// 周次模型：真实课表里周次是任意集合（偶数周但从第 4 周起、跳过 13-14 周），
/// 「单/双周」表达不了。这里盯住「能不能如实还原原文」和「压回紧凑写法不丢周」。
void main() {
  group('tryParse 认教务系统里的各种写法', () {
    test('连续范围 3-18', () {
      final set = WeekSet.tryParse('3-18')!;
      expect(set.weeks.length, 16);
      expect(set.contains(3), isTrue);
      expect(set.contains(18), isTrue);
      expect(set.contains(2), isFalse);
      expect(set.contains(19), isFalse);
    });

    test('偶数周从第 4 周起（单双周表达不了）', () {
      final set = WeekSet.tryParse('4,6,8,10,12,14,16,18')!;
      expect(set.weeks, {4, 6, 8, 10, 12, 14, 16, 18});
      expect(set.contains(2), isFalse);
    });

    test('跳周写法 3-12,15-18', () {
      final set = WeekSet.tryParse('3-12,15-18')!;
      expect(set.contains(12), isTrue);
      expect(set.contains(13), isFalse);
      expect(set.contains(14), isFalse);
      expect(set.contains(15), isTrue);
      expect(set.weeks.length, 14);
    });

    test('单点加范围 3,5-11', () {
      final set = WeekSet.tryParse('3,5-11')!;
      expect(set.weeks, {3, 5, 6, 7, 8, 9, 10, 11});
      expect(set.contains(4), isFalse);
    });

    test('中文外壳和全角标点', () {
      expect(WeekSet.tryParse('第3-16周')!.weeks.length, 14);
      expect(WeekSet.tryParse('3—16')!.weeks.length, 14);
      expect(WeekSet.tryParse('3至16')!.weeks.length, 14);
      expect(WeekSet.tryParse('3，5')!.weeks, {3, 5});
      expect(WeekSet.tryParse('（3-5）')!.weeks, {3, 4, 5});
    });

    test('写反的范围照样认', () {
      expect(WeekSet.tryParse('18-3')!.weeks, WeekSet.tryParse('3-18')!.weeks);
    });

    test('认不出时返回 null，绝不瞎猜', () {
      expect(WeekSet.tryParse(null), isNull);
      expect(WeekSet.tryParse(''), isNull);
      expect(WeekSet.tryParse('   '), isNull);
      // 「单/双周」这类文字要交给 weekParity 兜底，这里不能硬塞一个集合
      expect(WeekSet.tryParse('单周'), isNull);
      expect(WeekSet.tryParse('双周'), isNull);
      expect(WeekSet.tryParse('1-16单周'), isNull);
      expect(WeekSet.tryParse('每周'), isNull);
      expect(WeekSet.tryParse('abc'), isNull);
    });

    test('超出 1-30 周的脏数据被裁掉', () {
      final set = WeekSet.tryParse('0-3')!;
      expect(set.weeks, {1, 2, 3});
      expect(WeekSet.tryParse('31'), isNull);
      expect(WeekSet.tryParse('3-40')!.weeks.last, WeekSet.maxWeek);
    });
  });

  group('format 压回紧凑写法', () {
    test('整段压成 a-b', () {
      expect(WeekSet.format([3, 4, 5, 6, 7, 8]), '3-8');
    });

    test('零散的单独列，不硬凑范围', () {
      expect(WeekSet.format([4, 6, 8]), '4,6,8');
      // 两连不要写成 3-4，教务系统原文也不是这么写的
      expect(WeekSet.format([3, 4, 7]), '3,4,7');
    });

    test('混合：连续段 + 零散', () {
      expect(WeekSet.format([3, 4, 5, 7]), '3-5,7');
      expect(WeekSet.format([3, 4, 5, 9, 10, 11, 20]), '3-5,9-11,20');
    });

    test('乱序重复输入不炸', () {
      expect(WeekSet.format([5, 3, 4, 5, 3]), '3-5');
    });

    test('空输入得到空串', () {
      expect(WeekSet.format([]), '');
      expect(WeekSet.format([0, 31]), '');
    });

    test('format 与 tryParse 互为逆运算', () {
      for (final spec in ['3-18', '4,6,8,10,12,14,16,18', '3,5-11']) {
        final set = WeekSet.tryParse(spec)!;
        expect(WeekSet.format(set.weeks), spec);
        expect(WeekSet.tryParse(WeekSet.format(set.weeks))!.weeks, set.weeks);
      }
    });
  });

  group('并集：同一门课不同周段合成一条', () {
    test('线性代数 3-12,15-18 + 13-14 → 3-18', () {
      expect(WeekSet.unionToSpec(['3-12,15-18', '13-14']), '3-18');
    });

    test('微积分 3-10 + 11-18 → 3-18', () {
      expect(WeekSet.unionToSpec(['3-10', '11-18']), '3-18');
    });

    test('有认不出的段时只用能认的', () {
      expect(WeekSet.unionToSpec(['3-5', '单周']), '3-5');
    });

    test('全都认不出时给空串', () {
      expect(WeekSet.unionToSpec(['单周', '双周']), '');
    });
  });

  group('isContiguous', () {
    test('连续为真', () => expect(WeekSet.isContiguous([3, 4, 5]), isTrue));
    test('跳周为假', () => expect(WeekSet.isContiguous([3, 5]), isFalse));
    test('空集合为假（宁可当成「没周次」）', () {
      expect(WeekSet.isContiguous([]), isFalse);
    });
  });
}
