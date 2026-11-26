import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/models/timeline.dart';
import 'package:todo_app/widgets/timeline_item.dart';

/// 落位高亮的颜色回归（2026-11-25 真机验收抓到的）。
///
/// 当时写的是 `Color.lerp(淡黄, Colors.transparent, t)`。
/// `Colors.transparent` 是 0x00000000 —— 透明**黑**，不是"淡黄的透明版"。
/// lerp 会把 RGB 一路拉到 0，t≈0.5 时得到半透明深褐（实测压成 #C4C0B4），
/// 真机上看见的是一块脏灰褐色，完全不像"淡黄闪一下"。
///
/// 这组测试卡住两件事：起点色对得上，且中途 RGB 不许往黑掉。
void main() {
  const kFlash = Color(0xFFFFF1C2);

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  TimelineEntry eventEntry() => const TimelineEntry(
    key: 'event_1',
    sourceId: 1,
    type: EntryType.event,
    title: '测试事件',
    sortMinutes: 900,
    timeLabel: '15:00',
  );

  /// 从渲染树里捞高亮层用的 ColoredBox：它是 TimelineItem 根节点的唯一
  /// ColoredBox（卡片本身是 Card，不带这个）。
  Color? flashColor(WidgetTester tester) {
    final boxes = tester.widgetList<ColoredBox>(find.byType(ColoredBox));
    for (final box in boxes) {
      if (box.color.a > 0 && box.color.a < 1) return box.color;
    }
    return null;
  }

  testWidgets('高亮起点是淡黄，不是别的色', (tester) async {
    await tester.pumpWidget(
      host(TimelineItem(entry: eventEntry(), flash: true)),
    );
    // 第 0 帧：还没开始走，应当就是纯淡黄。
    final color = flashColor(tester) ?? kFlash;
    expect(color.r, moreOrLessEquals(1.0, epsilon: 0.02));
    expect(color.g, moreOrLessEquals(241 / 255, epsilon: 0.02));
    expect(color.b, moreOrLessEquals(194 / 255, epsilon: 0.02));
  });

  testWidgets('高亮褪到一半时 RGB 仍是淡黄，只是变透', (tester) async {
    await tester.pumpWidget(
      host(TimelineItem(entry: eventEntry(), flash: true)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    final color = flashColor(tester);
    expect(color, isNotNull, reason: '200ms 时应当还在高亮中途');
    // 关键断言：透明度在降，但 RGB 不许被拉向黑。
    expect(color!.a, lessThan(0.95));
    expect(color.r, moreOrLessEquals(1.0, epsilon: 0.02));
    expect(color.g, moreOrLessEquals(241 / 255, epsilon: 0.02));
    expect(color.b, moreOrLessEquals(194 / 255, epsilon: 0.02));
  });

  testWidgets('400ms 后高亮结束，不再有半透明色块', (tester) async {
    await tester.pumpWidget(
      host(TimelineItem(entry: eventEntry(), flash: true)),
    );
    await tester.pump(const Duration(milliseconds: 450));
    expect(flashColor(tester), isNull);
  });

  testWidgets('没有 flash 时不套高亮层', (tester) async {
    await tester.pumpWidget(host(TimelineItem(entry: eventEntry())));
    expect(flashColor(tester), isNull);
  });
}
