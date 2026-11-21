import 'package:flutter/services.dart';

/// 把全角数字 `０-９` 转成半角，其余字符原样保留。
///
/// 中文输入法会把数字打成全角，先归一化再过滤，否则用户敲出来的数字会被
/// 当成非法字符直接吞掉，表现成「按了键但没反应」。
String foldFullWidthDigits(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0xFF10 && rune <= 0xFF19) {
      buffer.writeCharCode(rune - 0xFF10 + 0x30);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// 只保留半角数字。
String _digitsOf(String input) =>
    foldFullWidthDigits(input).replaceAll(RegExp(r'[^0-9]'), '');

/// 按位插入分隔符：`[4, 6]` 表示在第 4、6 位数字前插 `-`。
String _group(String digits, int maxLength, List<int> positions, String sep) {
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length && i < maxLength; i++) {
    if (positions.contains(i)) buffer.write(sep);
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// 日期输入：只敲数字，横杠自动补。
///
/// `20261121` → `2026-11-21`。粘贴带横杠的完整日期也能识别。
class DateMaskFormatter extends TextInputFormatter {
  const DateMaskFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return _format(oldValue, newValue, 8, const [4, 6], '-');
  }
}

/// 时间输入：只敲数字，冒号自动补。
///
/// `0800` → `08:00`。
class TimeMaskFormatter extends TextInputFormatter {
  const TimeMaskFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return _format(oldValue, newValue, 4, const [2], ':');
  }
}

TextEditingValue _format(
  TextEditingValue oldValue,
  TextEditingValue newValue,
  int maxLength,
  List<int> positions,
  String separator,
) {
  var digits = _digitsOf(newValue.text);
  final oldDigits = _digitsOf(oldValue.text);

  // 退格落在分隔符上时，新文本只少了那个 `-`，数字一个没少。
  // 若不主动再删一位，用户会觉得「退格没反应」——补删一位让手感一致。
  if (digits == oldDigits &&
      newValue.text.length < oldValue.text.length &&
      digits.isNotEmpty) {
    digits = digits.substring(0, digits.length - 1);
  }

  final text = _group(digits, maxLength, positions, separator);
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
}
