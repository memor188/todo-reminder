// V1 UI 测试：验证三 tab 骨架、录入页与设置页的关键交互。
// V0 的通知探针测试已被真实 V1 UI 测试替换（不是删除测试）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/main.dart';
import 'package:todo_app/models/task.dart';
import 'package:todo_app/models/timeline.dart';
import 'package:todo_app/services/db_service.dart';
import 'package:todo_app/services/notification_service.dart';
import 'package:todo_app/services/settings_service.dart';

class FakeDbService extends DbService {
  AppData data = const AppData(courses: [], events: [], tasks: []);

  @override
  Future<AppData> queryAll() async => data;

  @override
  Future<void> setTaskDone(int id, {required bool done}) async {
    data = AppData(
      courses: data.courses,
      events: data.events,
      tasks: data.tasks.where((t) => t.id != id).toList(),
    );
  }
}

void main() {
  Widget buildApp({
    required FakeDbService db,
    bool permissionGranted = true,
    SettingsService? settings,
  }) {
    return App(
      notifications: NotificationService(),
      permissionGranted: permissionGranted,
      db: db,
      settings: settings ?? SettingsService.inMemory(),
    );
  }

  testWidgets('V1 首页有三 tab、添加按钮和空日程提示', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    expect(find.text('日程'), findsOneWidget);
    expect(find.text('课表'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.byKey(const Key('add_entry')), findsOneWidget);
    expect(find.text('这一天暂无日程'), findsOneWidget);
  });

  testWidgets('翻周按钮可切换到下一周', (WidgetTester tester) async {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final nextMonday = monday.add(const Duration(days: 7));
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('day_${dateKey(nextMonday)}')), findsNothing);
    await tester.tap(find.byKey(const Key('next_week')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('day_${dateKey(nextMonday)}')), findsOneWidget);
  });

  testWidgets('点课表 tab 显示 V2 占位，不崩溃', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();

    expect(find.textContaining('课表周网格将在 V2 实现'), findsOneWidget);
  });

  testWidgets('我的页显示 AI 配置与备份控件', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings_base')), findsOneWidget);
    expect(find.byKey(const Key('settings_key')), findsOneWidget);
    expect(find.byKey(const Key('settings_model')), findsOneWidget);
    expect(find.byKey(const Key('settings_export')), findsOneWidget);
    expect(find.byKey(const Key('settings_import')), findsOneWidget);
  });

  testWidgets('权限未授予时日程页显示警示', (WidgetTester tester) async {
    await tester.pumpWidget(
      buildApp(db: FakeDbService(), permissionGranted: false),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('通知权限未授予'), findsOneWidget);
  });

  testWidgets('点添加按钮进入录入页，空标题点保存给出提示', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_entry')));
    await tester.pumpAndSettle();

    expect(find.text('新建条目'), findsOneWidget);
    expect(find.byKey(const Key('input_title')), findsOneWidget);
    await tester.tap(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();
    expect(find.text('请先填事项'), findsOneWidget);
  });

  testWidgets('任务勾选后从时间线消失', (WidgetTester tester) async {
    final today = dateKey(DateTime.now());
    final db = FakeDbService();
    db.data = AppData(
      courses: const [],
      events: const [],
      tasks: [TaskItem(id: 1, title: '取快递', dueDate: today)],
    );
    await tester.pumpWidget(buildApp(db: db));
    await tester.pumpAndSettle();

    // 选中任务所在日期，确保条目出现在时间线
    await tester.tap(find.byKey(Key('day_$today')));
    await tester.pumpAndSettle();
    expect(find.text('取快递'), findsOneWidget);

    await tester.tap(find.byKey(const Key('toggle_task_1')));
    await tester.pumpAndSettle();
    expect(find.text('取快递'), findsNothing);
  });
}
