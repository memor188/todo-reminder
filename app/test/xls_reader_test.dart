import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/services/xls_reader.dart';

/// 老式 .xls（OLE2 + BIFF8）读取器。
///
/// 夹具是**真实文件**：教务系统导出的《学生个人课表_2026631168.xls》，
/// 15,872 字节。用真文件而不是手搓字节，是因为这里最容易踩的坑
/// （目录项名带 NUL、SST 跨 CONTINUE 段、RK 编码）只有真文件才踩得到。
void main() {
  // 夹具含本人学号与姓名，已排除出 git；本机上存在时这些用例必须全跑。
  final fixture = File('test/fixtures/timetable.xls');
  final hasFixture = fixture.existsSync();
  const skipReason = '缺少 test/fixtures/timetable.xls（本机真实课表，不入库）';

  late Uint8List bytes;
  late XlsSheet sheet;

  setUpAll(() {
    if (!hasFixture) return;
    bytes = fixture.readAsBytesSync();
    sheet = readFirstXlsSheet(bytes);
  });

  group('OLE2 容器', () {
    test('能定位到 Workbook 流并读出网格', () {
      expect(sheet.name, isNotEmpty);
      expect(sheet.rowCount, 8);
      expect(sheet.colCount, 8);
    });

    test('越界单元格返回空串，不抛异常', () {
      expect(sheet.cell(-1, 0), '');
      expect(sheet.cell(0, -1), '');
      expect(sheet.cell(999, 0), '');
      expect(sheet.cell(0, 99), '');
    });

    test('重复读同一份字节结果一致（无隐藏状态）', () {
      final again = readFirstXlsSheet(bytes);
      expect(again.rowCount, sheet.rowCount);
      expect(again.cell(4, 3), sheet.cell(4, 3));
    });
  }, skip: hasFixture ? false : skipReason);

  group('单元格内容', () {
    test('表头两行', () {
      expect(sheet.cell(0, 0), contains('学生个人课表'));
      expect(sheet.cell(1, 0), contains('2026-2027-1'));
    });

    test('星期表头在第三行、1..7 列', () {
      const names = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
      for (var i = 0; i < names.length; i++) {
        expect(sheet.cell(2, i + 1), names[i]);
      }
    });

    test('节次列写的是「一(01,02)」这种合集', () {
      expect(sheet.cell(3, 0), contains('01,02'));
      expect(sheet.cell(7, 0), contains('11,12,13'));
    });

    test('SST 里的长中文（含全角标点）没被截断', () {
      // 「新视界：前沿和热点 （新生篇之创新与求索 ——电子信息工程）」
      expect(sheet.cell(7, 3), contains('新生篇之创新与求索'));
      expect(sheet.cell(7, 3), contains('——'));
    });

    test('同一格里的多个课块用空行分隔，换行符保留了', () {
      final cell = sheet.cell(4, 3); // 星期三 大节二：线性代数两段（不同教师）
      expect(cell, contains('线性代数'));
      expect(cell, contains('陈哲'));
      expect(cell, contains('邬恩信'));
      expect(cell.split('\n').where((line) => line.trim().isEmpty), isNotEmpty);
    });

    test('空单元格是空串（教务系统常留一个空格占位）', () {
      expect(sheet.cell(3, 1).trim(), '');
      expect(sheet.cell(5, 3).trim(), '');
    });
  }, skip: hasFixture ? false : skipReason);

  group('坏文件给可读异常，不崩', () {
    test('不是 OLE2', () {
      final junk = Uint8List.fromList(List.filled(1024, 0x41));
      expect(
        () => readFirstXlsSheet(junk),
        throwsA(
          isA<XlsFormatException>().having(
            (e) => e.message,
            'message',
            contains('不是 .xls'),
          ),
        ),
      );
    });

    test('太短（连头都不够）', () {
      expect(
        () => readFirstXlsSheet(Uint8List.fromList([0xD0, 0xCF])),
        throwsA(isA<XlsFormatException>()),
      );
    });

    test('空文件', () {
      expect(
        () => readFirstXlsSheet(Uint8List(0)),
        throwsA(isA<XlsFormatException>()),
      );
    });
  });
}
