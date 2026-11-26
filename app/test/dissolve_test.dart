import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/models/timeline.dart';
import 'package:todo_app/widgets/day_timeline_list.dart';
import 'package:todo_app/widgets/disintegrate/index.dart';
import 'package:todo_app/widgets/timeline_item.dart';

/// 勾选完成的粉尘消散（2026-11-26 改用 GPU shader）。
///
/// 四段：散开(progress 0→1) → 收起补位 → 重组(progress 1→0) → 淡黄高亮。
/// 这组测试盯的是 progress 在正确阶段取正确值，以及用户定的取舍：
/// 取消勾选不播粉尘（保持普通淡入）。
void main() {
  final day = DateTime(2026, 11, 25);

  TimelineEntry task({bool done = false, String key = 'task_1', int min = 900}) =>
      TimelineEntry(
        key: key,
        sourceId: int.tryParse(key.split('_').last) ?? 1,
        type: EntryType.task,
        title: '取快递',
        sortMinutes: min,
        timeLabel: '15:00',
        done: done,
      );

  /// 课程没有勾选动作，下课后由时间推进自动进完成区（2026-11-26）。
  TimelineEntry courseEntry({String key = 'course_1'}) => TimelineEntry(
        key: key,
        sourceId: 1,
        type: EntryType.course,
        title: '高等数学',
        sortMinutes: 480,
        endMinutes: 640,
        deadlineMinutes: 640,
        timeLabel: '08:00–09:40',
      );

  Widget host(DaySections sections, {String? flashKey}) {
    return MaterialApp(
      home: Scaffold(
        body: DayTimelineList(
          day: day,
          sections: sections,
          now: DateTime(2026, 11, 25, 8, 0),
          flashKey: flashKey,
        ),
      ),
    );
  }

  Future<void> tick(WidgetTester tester, int ms) =>
      tester.pump(Duration(milliseconds: ms));

  /// 从渲染树里找 dissolve widget 的 progress。
  double? progressOf(WidgetTester tester) {
    final found = tester.widgetList<DisintegrateEffect>(
      find.byType(DisintegrateEffect),
    );
    if (found.isEmpty) return null;
    return found.first.progress;
  }

  testWidgets('worker: DissintegrateEffect 按 progress 渲染，边界不炸',
      (tester) async {
    // 直接把 progress 塞进去，确认 0/0.5/1 三个边界都能 build。
    for (final p in [0.0, 0.5, 1.0]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DisintegrateEffect(
            progress: p,
            child: const SizedBox(width: 100, height: 60),
          ),
        ),
      ));
      expect(find.byType(DisintegrateEffect), findsOneWidget,
          reason: 'progress=$p 应当正常渲染');
      await tick(tester, 100);
    }
  });

  testWidgets('TimelineItem 有 dissolveProgress 时套 shader，没有时不套',
      (tester) async {
    final e = task();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TimelineItem(entry: e)),
    ));
    expect(find.byType(DisintegrateEffect), findsNothing);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TimelineItem(entry: e, dissolveProgress: 0.5)),
    ));
    expect(find.byKey(const Key('dissolve_task_1')), findsOneWidget);
  });

  testWidgets('勾选：散开阶段 progress 往上走，重组阶段往下走',
      (tester) async {
    await tester.pumpWidget(host(DaySections(normal: [task(done: false)])));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      host(DaySections(done: [task(done: true)]), flashKey: 'task_1'),
    );
    await tester.pump();
    await tester.pump();

    // ① 散开（0–500ms）：progress 从 0 往 1 走。
    await tick(tester, 200);
    final duringDissipate = progressOf(tester);
    expect(duringDissipate, isNotNull, reason: '散开阶段应有 shader');
    expect(duringDissipate!, greaterThan(0.0),
        reason: '散开阶段 progress 应大于 0');
    expect(duringDissipate, lessThan(1.0),
        reason: '散开还没结束，progress 不该到 1');

    // 越过 500ms 进入收起阶段（500–1100ms）。源行必须保持 progress=1，
    // 不能变 null —— 否则 shader 被摘掉、卡片"复活"后再被 Opacity 淡出，
    // 就是用户看到的"粉末散了→卡片又冒出来→再隐去"。
    await tick(tester, 350); // 累计 550ms，刚进收起
    final duringCollapse = progressOf(tester);
    expect(duringCollapse, isNotNull,
        reason: '收起阶段源行仍须挂 shader，不能让卡片复活');
    expect(duringCollapse, closeTo(1.0, 0.01),
        reason: '收起阶段 progress 必须是 1（粉尘散尽、卡片不可见）');

    // 收起走完（1100ms），进入重组。
    await tick(tester, 550);
    final atReassembleStart = progressOf(tester);
    expect(atReassembleStart, isNotNull, reason: '重组阶段应有 shader');

    // ③ 重组中：progress 从 1 往 0 走，比刚插入时小。
    await tick(tester, 400);
    final duringReassemble = progressOf(tester);
    expect(duringReassemble, isNotNull);
    expect(duringReassemble!, lessThan(atReassembleStart!),
        reason: '重组阶段 progress 应当往下走（粉尘聚回来）');

    // 跑完剩下的序列，清掉 controller / timer。
    await tick(tester, 500);
    await tester.pumpAndSettle();
  });

  testWidgets('取消勾选不播粉尘，走普通淡入', (tester) async {
    await tester.pumpWidget(host(DaySections(done: [task(done: true)])));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      host(DaySections(normal: [task(done: false)]), flashKey: 'task_1'),
    );
    await tester.pump();
    await tester.pump();

    for (final ms in [200, 400, 400, 400, 400]) {
      await tick(tester, ms);
      expect(find.byType(DisintegrateEffect), findsNothing,
          reason: '取消勾选不该播粉尘（用户定的取舍）');
    }
    await tester.pumpAndSettle();
  });

  testWidgets('课程自动完成不播粉尘（时间推进≠勾选）', (tester) async {
    // 回归：课程下课后 resolveEntryState 返回 done，_completionKey 若不看
    // 类型会误判成"刚勾完成"，凭空炸一次粉尘。课程永远不该播勾选动画。
    await tester.pumpWidget(host(DaySections(normal: [courseEntry()])));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      host(DaySections(done: [courseEntry()])),
    );
    await tester.pump();
    await tester.pump();

    for (final ms in [200, 400, 400, 400, 400, 400]) {
      await tick(tester, ms);
      expect(find.byType(DisintegrateEffect), findsNothing,
          reason: '课程随时间长到完成区，不是勾选，不该播粉尘');
    }
    await tester.pumpAndSettle();
  });

  testWidgets('勾当天最后一条：源行强制收起，重组后不出现重复行', (tester) async {
    // 回归：[a,b,c] 勾掉 c 后 next=[a,b,已完成头,c]，LCS 是 [a,b,c]，
    // c 会被当成"位置不变"而不 remove —— 那样散开后又原样冒出来、
    // 也不播重组。_removePhase 必须强制剔除源行。
    final a = task(key: 'task_1', min: 540);
    final b = task(key: 'task_2', min: 600);
    final c = task(key: 'task_3', min: 660);
    final cDone = task(key: 'task_3', min: 660, done: true);

    await tester.pumpWidget(host(DaySections(normal: [a, b, c])));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tile_task_3')), findsOneWidget);

    await tester.pumpWidget(host(
      DaySections(normal: [a, b], done: [cDone]),
      flashKey: 'task_3',
    ));
    await tester.pump();
    await tester.pump();

    await tick(tester, 200);
    expect(progressOf(tester), isNotNull,
        reason: '散开阶段源行应有 shader');

    await tick(tester, 350);
    await tick(tester, 750);
    await tick(tester, 400);
    expect(progressOf(tester), isNotNull,
        reason: '重组阶段目标行应有 shader');

    await tick(tester, 900);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tile_task_3')), findsOneWidget,
        reason: '重组后只该有一条，不能重复');
    expect(find.byKey(const Key('section_done')), findsOneWidget);
  });

  testWidgets('散开阶段下方条目纹丝不动', (tester) async {
    final a = task(key: 'task_1', min: 540);
    final b = task(key: 'task_2', min: 600);
    final aDone = task(key: 'task_1', min: 540, done: true);

    await tester.pumpWidget(host(DaySections(normal: [a, b])));
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.byKey(const Key('tile_task_2'))).dy;

    await tester.pumpWidget(host(
      DaySections(normal: [b], done: [aDone]),
      flashKey: 'task_1',
    ));
    await tester.pump();
    await tester.pump();

    await tick(tester, 300);
    final during = tester.getTopLeft(find.byKey(const Key('tile_task_2'))).dy;
    expect(during, moreOrLessEquals(before, epsilon: 1),
        reason: '散开阶段下方不能动');

    await tick(tester, 2100);
    await tester.pumpAndSettle();
  });
}
