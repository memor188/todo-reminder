import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/models/period_table.dart';
import 'package:todo_app/services/ai_service.dart';
import 'package:todo_app/services/timetable_file_parser.dart';
import 'package:todo_app/services/xls_reader.dart';

/// 教务系统 .xls → 课程草稿。
///
/// 夹具是真实课表（汕头大学 2026-2027-1，15,872 字节）。这份文件里有三个
/// 让「单双周」模型当场失效的地方，必须逐条对上：
/// - ELC1 周二? 不，周四 8 节：`4,6,8,10,12,14,16,18`（偶数周但从第 4 周起）；
/// - 线性代数 3-12,15-18（陈哲）+ 13-14（邬恩信），同地点 → 应合成 3-18 周一条；
/// - 新视界连开 8 个块（第 8~15 周各换一位老师），应合成 8-15 周一条。
void main() {
  const table = PeriodTable.shantouDefault;
  // 夹具含本人学号与姓名，已排除出 git；本机上存在时这些用例必须全跑。
  final fixture = File('test/fixtures/timetable.xls');
  final hasFixture = fixture.existsSync();
  const skipReason = '缺少 test/fixtures/timetable.xls（本机真实课表，不入库）';

  late List<AiCourseDraft> drafts;

  setUpAll(() {
    if (!hasFixture) return;
    drafts = coursesFromXlsSheet(readFirstXlsSheet(fixture.readAsBytesSync()), table);
  });

  AiCourseDraft find(String title, {int? day, String? start}) => drafts.firstWhere(
    (draft) =>
        draft.title == title &&
        (day == null || draft.dayOfWeek == day) &&
        (start == null || draft.startTime == start),
    orElse: () => throw StateError('没找到「$title」day=$day start=$start'),
  );

  group('整份课表', () {
    test('23 个课块合并成 12 条课程，全部能落库', () {
      expect(drafts.length, 12);
      expect(drafts.every((draft) => draft.resolved), isTrue);
      expect(
        drafts.where((draft) => draft.unresolvedReason != null),
        isEmpty,
      );
    });

    test('每门课都有教师、地点、周次', () {
      for (final draft in drafts) {
        expect(draft.teacher, isNotNull, reason: '${draft.title} 缺教师');
        expect(draft.location, isNotNull, reason: '${draft.title} 缺地点');
        expect(draft.weeks, isNotNull, reason: '${draft.title} 缺周次');
      }
    });

    test('课名、周几、节次都对得上原文', () {
      // 星期二 大节二(03,04,05) → 10:00 起
      final xigai = find('习近平新时代中国特色社会主义思想概论', day: 2);
      expect(xigai.startTime, '10:00');
      expect(xigai.endTime, '12:35'); // 03-04-05 三节连上
      expect(xigai.location, '东海岸-E教420-阶梯');
      expect(xigai.teacher, '卢明佳');
      expect(xigai.weeks, '3-18');

      // 星期三 线上 A~C 节 → 19:20–21:55
      final xinshijie = find('新视界：前沿和热点 （新生篇之创新与求索 ——电子信息工程）');
      expect(xinshijie.dayOfWeek, 3);
      expect(xinshijie.startTime, '19:20');
      expect(xinshijie.endTime, '21:55');
    });
  }, skip: hasFixture ? false : skipReason);

  group('周次：单双周表达不了的真实写法', () {
    test('偶数周但从第 4 周起', () {
      final elc = find('ELC1综合英语与沟通能力', day: 4);
      expect(elc.weeks, '4,6,8,10,12,14,16,18');
      expect(elc.startTime, '08:00');
      expect(elc.endTime, '09:40');
    });

    test('同一门课两段周次合并，教师留第一位', () {
      final linalg = find('线性代数');
      expect(linalg.weeks, '3-18'); // 3-12,15-18 ∪ 13-14
      expect(linalg.teacher, '陈哲');
      expect(linalg.location, '东海岸-E教201-阶梯');
      // 合并后只该剩一条
      expect(drafts.where((draft) => draft.title == '线性代数').length, 1);
    });

    test('连开 8 个课块的新视界压成 8-15 周一条', () {
      final xinshijie = drafts.where(
        (draft) => draft.title.startsWith('新视界'),
      );
      expect(xinshijie.length, 1);
      expect(xinshijie.single.weeks, '8-15');
      expect(xinshijie.single.teacher, '赖李洋'); // 第一位老师
    });

    test('单点加范围 3,5-11', () {
      expect(find('形势与政策教育').weeks, '3,5-11');
    });

    test('同一门课不同星期不合并（ELC1 周一、周四各一条）', () {
      final elc = drafts.where(
        (draft) => draft.title == 'ELC1综合英语与沟通能力',
      );
      expect(elc.length, 2);
      expect(elc.map((draft) => draft.dayOfWeek).toSet(), {1, 4});
    });
  }, skip: hasFixture ? false : skipReason);

  group('节次编号换算', () {
    test('导出用的 01..13 逐个数成第几个，不是当成数字', () {
      final engineering = find('工程设计与工程伦理基础');
      expect(engineering.period, contains('6')); // 06-07 节
      expect(engineering.startTime, '14:00');
      expect(engineering.endTime, '15:40');

      final ai = find('人工智能基础');
      expect(ai.startTime, '16:00'); // 08-09 节
      expect(ai.endTime, '17:40');
    });

    test('上午最后一节和下午第一节不会串', () {
      final english = find('ELC1综合英语与沟通能力', day: 1);
      expect(english.startTime, '16:00');
      expect(english.weeks, '3-18');
    });
  }, skip: hasFixture ? false : skipReason);

  group('前置条件与兜底', () {
    test('作息表为空时直接返回空列表（换算不了）', () {
      expect(
        coursesFromXlsSheet(
          const XlsSheet(name: 'S', rows: []),
          const PeriodTable([]),
        ),
        isEmpty,
      );
    });

    test('没有星期表头的表不当课表处理', () {
      const sheet = XlsSheet(
        name: 'S',
        rows: [
          ['姓名', '成绩'],
          ['张三', '90'],
        ],
      );
      expect(coursesFromXlsSheet(sheet, table), isEmpty);
    });

    test('节次超出作息表行数 → 标记未解析而不是瞎给时间', () async {
      const sheet = XlsSheet(
        name: 'S',
        rows: [
          ['', '星期一', '星期二', '星期三', '星期四', '星期五'],
          ['一(01,02)', '', '', '', '', ''],
          ['四(14,15)', '超纲课\n某老师\n3-18([周])[14-15节]\n东海岸-E教101', '', '', '', ''],
        ],
      );
      final result = coursesFromXlsSheet(sheet, table);
      final draft = result.single;
      expect(draft.title, '超纲课');
      expect(draft.startTime, isNull);
      expect(draft.resolved, isFalse);
      expect(draft.unresolvedReason, contains('超出作息表行数'));
      // 周次和教师照样保留，方便用户补完时间直接导
      expect(draft.weeks, '3-18');
      expect(draft.teacher, '某老师');
    });
  });

  group('mergeSameCourse 合并规则', () {
    AiCourseDraft draft({
      String title = '课',
      int day = 1,
      String start = '08:00',
      String? location = 'E101',
      String? teacher,
      String? weeks,
    }) => AiCourseDraft(
      title: title,
      dayOfWeek: day,
      startTime: start,
      endTime: '09:40',
      location: location,
      teacher: teacher,
      weeks: weeks,
    );

    test('同课/同天/同时间/同地点 → 合并，周次取并集', () {
      final merged = mergeSameCourse([
        draft(weeks: '3-12,15-18', teacher: '陈哲'),
        draft(weeks: '13-14', teacher: '邬恩信'),
      ]);
      expect(merged.single.weeks, '3-18');
      expect(merged.single.teacher, '陈哲');
    });

    test('地点不同不合并（同一门课分两个教室不算同一节）', () {
      final merged = mergeSameCourse([
        draft(location: 'E101'),
        draft(location: 'E202'),
      ]);
      expect(merged.length, 2);
    });

    test('时间不同不合并', () {
      final merged = mergeSameCourse([
        draft(start: '08:00'),
        draft(start: '10:00'),
      ]);
      expect(merged.length, 2);
    });

    test('合并顺序保持首次出现的次序', () {
      final merged = mergeSameCourse([
        draft(title: '甲'),
        draft(title: '乙'),
        draft(title: '甲'),
      ]);
      expect(merged.map((d) => d.title), ['甲', '乙']);
    });
  });

  group('纯文本文件入口', () {
    test('认识的文本表格后缀', () {
      for (final name in ['a.csv', 'b.TSV', 'c.txt', 'd.md', 'e.html']) {
        expect(isTextTimetable(name), isTrue, reason: name);
      }
      for (final name in ['a.xls', 'a.xlsx', 'a.pdf', 'a.png']) {
        expect(isTextTimetable(name), isFalse, reason: name);
      }
    });

    test('UTF-8 中文正常解出', () {
      final bytes = Uint8List.fromList(utf8.encode('星期一 高数 3-18周'));
      expect(textFromFile(bytes), contains('高数'));
    });
  });
}
