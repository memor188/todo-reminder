// 掩码输入：日期只敲数字自动补横杠、时间只敲数字自动补冒号。
// 2026-11-21 用户要求：分隔符「就在那」，不用手打。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/widgets/masked_formatters.dart';

TextEditingValue _value(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

void main() {
  group('DateMaskFormatter', () {
    const formatter = DateMaskFormatter();

    test('8 位数字自动补成 yyyy-MM-dd', () {
      final result = formatter.formatEditUpdate(
        TextEditingValue.empty,
        _value('20261121'),
      );
      expect(result.text, '2026-11-21');
    });

    test('中文输入法打出的全角数字也能认', () {
      final result = formatter.formatEditUpdate(
        TextEditingValue.empty,
        _value('２０２６１１２１'),
      );
      expect(result.text, '2026-11-21');
    });

    test('粘贴带横杠的完整日期不会被破坏', () {
      final result = formatter.formatEditUpdate(
        TextEditingValue.empty,
        _value('2026-11-21'),
      );
      expect(result.text, '2026-11-21');
    });

    test('超过 8 位直接截断', () {
      final result = formatter.formatEditUpdate(
        TextEditingValue.empty,
        _value('202611219999'),
      );
      expect(result.text, '2026-11-21');
    });

    test('退格落在横杠上时连带删掉一位数字', () {
      // 文本是 `2026-11-`，退格删掉末尾横杠，数字一个没少。
      // 若不补删一位，用户会觉得「退格没反应」。
      final result = formatter.formatEditUpdate(
        _value('2026-11-'),
        _value('2026-11'),
      );
      expect(result.text, '2026-1');
    });

    test('正常退格只删一位数字', () {
      final result = formatter.formatEditUpdate(
        _value('2026-11-21'),
        _value('2026-11-2'),
      );
      expect(result.text, '2026-11-2');
    });

    test('清空后是空文本', () {
      final result = formatter.formatEditUpdate(
        _value('2026-11-21'),
        TextEditingValue.empty,
      );
      expect(result.text, '');
    });
  });

  group('TimeMaskFormatter', () {
    const formatter = TimeMaskFormatter();

    test('4 位数字自动补成 HH:mm', () {
      final result = formatter.formatEditUpdate(
        TextEditingValue.empty,
        _value('0800'),
      );
      expect(result.text, '08:00');
    });

    test('粘贴带冒号的时间能识别', () {
      final result = formatter.formatEditUpdate(
        TextEditingValue.empty,
        _value('17:30'),
      );
      expect(result.text, '17:30');
    });

    test('超过 4 位截断', () {
      final result = formatter.formatEditUpdate(
        TextEditingValue.empty,
        _value('080012'),
      );
      expect(result.text, '08:00');
    });

    test('退格落在冒号上时连带删掉一位数字', () {
      final result = formatter.formatEditUpdate(
        _value('08:'),
        _value('08'),
      );
      expect(result.text, '0');
    });
  });
}
