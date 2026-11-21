// 学期方案：当前日期命中哪个方案就自动选哪个（2026-11-21 用户拍板）。
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/models/semester_plan.dart';

void main() {
  const autumn = SemesterPlan(
    id: 'autumn',
    name: '2026秋',
    start: '2026-09-01',
    end: '2027-01-15',
  );
  const wholeYear = SemesterPlan(
    id: 'year',
    name: '2026-2027学年',
    start: '2026-08-01',
    end: '2027-07-31',
  );
  const spring = SemesterPlan(
    id: 'spring',
    name: '2027春',
    start: '2027-02-20',
    end: '2027-07-10',
  );

  group('SemesterPlan.contains', () {
    test('首尾当天都算在学期内', () {
      expect(autumn.contains(DateTime(2026, 9, 1)), isTrue);
      expect(autumn.contains(DateTime(2027, 1, 15)), isTrue);
    });

    test('只比日期不比钟点', () {
      expect(autumn.contains(DateTime(2027, 1, 15, 23, 59)), isTrue);
      expect(autumn.contains(DateTime(2026, 9, 1, 0, 0)), isTrue);
    });

    test('学期外返回 false', () {
      expect(autumn.contains(DateTime(2026, 7, 1)), isFalse);
      expect(autumn.contains(DateTime(2027, 3, 1)), isFalse);
    });

    test('起止日期坏掉的方案不匹配任何日期', () {
      const broken = SemesterPlan(
        id: 'bad',
        name: '坏数据',
        start: 'nope',
        end: '2027-01-15',
      );
      expect(broken.contains(DateTime(2026, 11, 21)), isFalse);
    });
  });

  group('SemesterPlan.pickForDate', () {
    test('命中当前学期', () {
      final picked = SemesterPlan.pickForDate([autumn], DateTime(2026, 11, 21));
      expect(picked?.id, 'autumn');
    });

    test('不在任何学期内返回 null', () {
      final picked = SemesterPlan.pickForDate([autumn], DateTime(2026, 7, 1));
      expect(picked, isNull);
    });

    test('方案重叠时取范围更窄的那个', () {
      final picked = SemesterPlan.pickForDate(
        [wholeYear, autumn],
        DateTime(2026, 11, 21),
      );
      expect(picked?.id, 'autumn');
    });

    test('秋季学期内不会被春季学期抢走', () {
      final picked = SemesterPlan.pickForDate(
        [autumn, spring],
        DateTime(2026, 11, 21),
      );
      expect(picked?.id, 'autumn');
    });

    test('春季学期内命中春季方案', () {
      final picked = SemesterPlan.pickForDate(
        [autumn, spring],
        DateTime(2027, 4, 1),
      );
      expect(picked?.id, 'spring');
    });

    test('空列表返回 null', () {
      expect(SemesterPlan.pickForDate(const [], DateTime(2026, 11, 21)), isNull);
    });
  });

  group('SemesterPlan 序列化', () {
    test('存进 Map 再读回来字段不丢', () {
      final restored = SemesterPlan.fromMap(autumn.toMap());
      expect(restored?.id, autumn.id);
      expect(restored?.name, autumn.name);
      expect(restored?.start, autumn.start);
      expect(restored?.end, autumn.end);
    });

    test('缺字段或日期非法返回 null，不抛异常', () {
      expect(SemesterPlan.fromMap({'id': 'x', 'name': 'y'}), isNull);
      expect(
        SemesterPlan.fromMap({
          'id': 'x',
          'name': 'y',
          'start': 'abc',
          'end': '2027-01-15',
        }),
        isNull,
      );
    });
  });
}
