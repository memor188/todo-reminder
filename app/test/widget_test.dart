// V1 UI 测试：验证三 tab 骨架、录入页与设置页的关键交互。
// V0 的通知探针测试已被真实 V1 UI 测试替换（不是删除测试）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/main.dart';
import 'package:todo_app/models/course.dart';
import 'package:todo_app/models/task.dart';
import 'package:todo_app/models/timeline.dart';
import 'package:todo_app/services/db_service.dart';
import 'package:todo_app/services/notification_service.dart';
import 'package:todo_app/services/settings_service.dart';

class FakeDbService extends DbService {
  AppData data = const AppData(courses: [], events: [], tasks: []);
  final List<Course> savedCourses = [];

  @override
  Future<AppData> queryAll() async => data;

  @override
  Future<int> insertCourse(Course item) async {
    savedCourses.add(item);
    return savedCourses.length;
  }

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

  testWidgets('课表 tab 显示周网格与翻周按钮', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tt_prev_week')), findsOneWidget);
    expect(find.byKey(const Key('tt_next_week')), findsOneWidget);
    expect(find.text('周一'), findsWidgets);
    expect(find.text('周日'), findsWidgets);
  });

  testWidgets('课程录入可选择单双周并带回保存', (WidgetTester tester) async {
    final db = FakeDbService();
    await tester.pumpWidget(buildApp(db: db));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('input_week_parity')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('input_title')), '高数');
    await tester.tap(find.text('单周'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();

    expect(db.savedCourses, hasLength(1));
    expect(db.savedCourses.single.weekParity, 1);
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

  testWidgets('AI 对话页未配 key 时给出可读提示，不发请求', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings_ai_chat')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('ai_input')), '周五17点E栋104考试');
    await tester.tap(find.byKey(const Key('ai_parse')));
    await tester.pumpAndSettle();

    expect(find.textContaining('请先在'), findsOneWidget);
    expect(find.byKey(const Key('ai_confirm_1')), findsNothing);
  });

  testWidgets('AI 页示例按钮能一键填入样例文本', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings_ai_chat')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ai_sample_1')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byKey(const Key('ai_input')));
    expect(field.controller!.text, '周五17点E栋104考试，周日交作业');
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
