// V1 UI 测试：验证三 tab 骨架、录入页与设置页的关键交互。
// V0 的通知探针测试已被真实 V1 UI 测试替换（不是删除测试）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/main.dart';
import 'package:todo_app/models/course.dart';
import 'package:todo_app/models/event_item.dart';
import 'package:todo_app/models/semester_plan.dart';
import 'package:todo_app/models/task.dart';
import 'package:todo_app/models/timeline.dart';
import 'package:todo_app/services/db_service.dart';
import 'package:todo_app/services/notification_service.dart';
import 'package:todo_app/services/settings_service.dart';

class FakeDbService extends DbService {
  AppData data = const AppData(courses: [], events: [], tasks: []);
  final List<Course> savedCourses = [];

  /// 编辑相关：测试里预置一条事件，记录 update / delete 是否被调用。
  EventItem? storedEvent;
  EventItem? updatedEvent;
  int? deletedEventId;

  @override
  Future<AppData> queryAll() async => data;

  @override
  Future<int> insertCourse(Course item) async {
    savedCourses.add(item);
    return savedCourses.length;
  }

  @override
  Future<EventItem?> findEvent(int id) async => storedEvent;

  @override
  Future<void> updateEvent(EventItem item) async {
    updatedEvent = item;
  }

  @override
  Future<void> deleteEvent(int id) async {
    deletedEventId = id;
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

  /// 把测试视口换成接近真机的竖屏尺寸。
  ///
  /// Flutter 测试默认视口只有 800×600 逻辑像素，而手机竖屏是 360×800 上下。
  /// 录入页 V3 加了提前量和优先级两组控件后，保存按钮在 600 高的视口里会掉到
  /// 折叠线以下——`ensureVisible` 也拉不上来（内容总高只比视口高一点，滚动余量
  /// 不够），点击就落空了。给个真机高度，测试关注的才是逻辑而不是视口太矮。
  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 3840);
    tester.view.devicePixelRatio = 3.0; // → 360 × 1280 逻辑像素
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
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
    // 表头是单字周几（参考图样式），不再是「周一」
    expect(find.text('一'), findsWidgets);
    expect(find.text('日'), findsWidgets);
    // 左栏是节次 + 起止时刻
    expect(find.text('08:00'), findsOneWidget);
    expect(find.text('08:45'), findsOneWidget);
  });

  testWidgets('课表可以左右滑动翻周（不用点箭头）', (WidgetTester tester) async {
    // 视口换成 360 宽：拖 200px 就过了半页，PageView 才会翻页。
    // 默认 800 宽时同样拖 320px 只占 40%，会弹回原页。
    useTallScreen(tester);
    final now = DateTime.now();
    final monday = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - 1));
    final nextMonday = monday.add(const Duration(days: 7));
    final nextSunday = nextMonday.add(const Duration(days: 6));
    String range(DateTime from, DateTime to) =>
        '${from.month}月${from.day}日 - ${to.month}月${to.day}日';

    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();

    expect(find.text(range(monday, monday.add(const Duration(days: 6)))),
        findsOneWidget);

    // 往左滑 = 下一周
    await tester.drag(
      find.byKey(const Key('tt_week_pager')),
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();

    expect(find.text(range(nextMonday, nextSunday)), findsOneWidget);

    // 往右滑 = 回到本周
    await tester.drag(
      find.byKey(const Key('tt_week_pager')),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle();

    expect(find.text(range(monday, monday.add(const Duration(days: 6)))),
        findsOneWidget);
  });

  testWidgets('课程录入可选择单双周并带回保存', (WidgetTester tester) async {
    useTallScreen(tester);
    final db = FakeDbService();
    await tester.pumpWidget(buildApp(db: db));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('input_week_parity')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('input_title')), '高数');
    await tester.ensureVisible(find.text('单周'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单周'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();

    expect(db.savedCourses, hasLength(1));
    expect(db.savedCourses.single.weekParity, 1);
  });

  testWidgets('课程录入能填教师与周次，一起落库', (WidgetTester tester) async {
    useTallScreen(tester);
    final db = FakeDbService();
    await tester.pumpWidget(buildApp(db: db));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('input_title')), '线性代数');
    await tester.ensureVisible(find.byKey(const Key('input_teacher')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('input_teacher')), '陈哲');
    await tester.ensureVisible(find.byKey(const Key('input_weeks')));
    await tester.pumpAndSettle();
    // 故意写乱一点：全角逗号 + 倒序范围，保存时应被归一化成 3-18
    await tester.enterText(find.byKey(const Key('input_weeks')), '18-3');
    await tester.ensureVisible(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();

    expect(db.savedCourses, hasLength(1));
    final course = db.savedCourses.single;
    expect(course.teacher, '陈哲');
    expect(course.weeks, '3-18');
  });

  testWidgets('周次写法认不出来时拦下，不写脏数据', (WidgetTester tester) async {
    useTallScreen(tester);
    final db = FakeDbService();
    await tester.pumpWidget(buildApp(db: db));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('input_title')), '某课');
    await tester.ensureVisible(find.byKey(const Key('input_weeks')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('input_weeks')), '单周');
    await tester.ensureVisible(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();

    expect(db.savedCourses, isEmpty);
    expect(
      tester.widget<Text>(find.byKey(const Key('input_message'))).data,
      contains('周次认不出来'),
    );
  });

  testWidgets('我的页显示 AI 配置与备份控件', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings_base')), findsOneWidget);
    expect(find.byKey(const Key('settings_key')), findsOneWidget);
    expect(find.byKey(const Key('settings_model')), findsOneWidget);

    // 我的页是 ListView，备份区在首屏之外，必须先滚下去才会构建。
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings_export')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

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
    useTallScreen(tester);
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_entry')));
    await tester.pumpAndSettle();

    expect(find.text('新建条目'), findsOneWidget);
    expect(find.byKey(const Key('input_title')), findsOneWidget);
    // V3 加了「提前提醒」下拉框，表单变高，保存按钮落到折叠线以下。
    final saveButton = find.byKey(const Key('save_entry'));
    await tester.ensureVisible(saveButton);
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
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

    // 第三个示例是真实的长段活动通知，验证一键填入且关键信息完整。
    await tester.ensureVisible(find.byKey(const Key('ai_sample_3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai_sample_3')));
    await tester.pumpAndSettle();

    final longField = tester.widget<TextField>(find.byKey(const Key('ai_input')));
    expect(longField.controller!.text, contains('党旗下的青春'));
    expect(longField.controller!.text, contains('E教101-阶梯教室'));
    expect(longField.controller!.text, contains('15:00—17:00'));
  });

  testWidgets('日程页有 AI 录入入口，位于加号旁边', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai_entry')), findsOneWidget);
    expect(find.byKey(const Key('add_entry')), findsOneWidget);
  });

  testWidgets('点日程条目进入编辑页，标题预填且可保存修改', (WidgetTester tester) async {
    useTallScreen(tester);
    final today = dateKey(DateTime.now());
    final db = FakeDbService();
    db.storedEvent = EventItem(
      id: 5,
      title: '考试',
      startAt: '${today}T23:30:00',
      location: 'E104',
    );
    db.data = AppData(courses: [], events: [db.storedEvent!], tasks: []);

    await tester.pumpWidget(buildApp(db: db));
    await tester.pumpAndSettle();

    await tester.tap(find.text('考试'));
    await tester.pumpAndSettle();

    expect(find.text('编辑条目'), findsOneWidget);
    expect(find.byKey(const Key('delete_entry')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('input_title')), '补考');
    await tester.ensureVisible(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();

    expect(db.updatedEvent?.title, '补考');
    expect(db.updatedEvent?.id, 5);
  });

  testWidgets('编辑条目可改优先级，保存后带回', (WidgetTester tester) async {
    useTallScreen(tester);
    final today = dateKey(DateTime.now());
    final db = FakeDbService();
    db.storedEvent = EventItem(
      id: 9,
      title: '考试',
      startAt: '${today}T23:50:00',
    );
    db.data = AppData(courses: [], events: [db.storedEvent!], tasks: []);

    await tester.pumpWidget(buildApp(db: db));
    await tester.pumpAndSettle();

    await tester.tap(find.text('考试'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('input_priority')), findsOneWidget);
    await tester.ensureVisible(find.text('紧急'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('紧急'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();

    expect(db.updatedEvent?.priority, priorityUrgent);
  });

  testWidgets('编辑页删除需二次确认', (WidgetTester tester) async {
    final today = dateKey(DateTime.now());
    final db = FakeDbService();
    db.storedEvent = EventItem(
      id: 7,
      title: '讲座',
      startAt: '${today}T23:40:00',
    );
    db.data = AppData(courses: [], events: [db.storedEvent!], tasks: []);

    await tester.pumpWidget(buildApp(db: db));
    await tester.pumpAndSettle();

    await tester.tap(find.text('讲座'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('delete_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete_entry')));
    await tester.pumpAndSettle();

    expect(find.text('删除这条？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm_delete')));
    await tester.pumpAndSettle();

    expect(db.deletedEventId, 7);
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

  testWidgets('我的页可进入学期方案并新增一条', (WidgetTester tester) async {
    final settings = SettingsService.inMemory();
    await tester.pumpWidget(buildApp(db: FakeDbService(), settings: settings));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings_semester_plans')));
    await tester.pumpAndSettle();

    expect(find.text('还没有方案。\n建一个「2026秋」，以后新建课程就能一键套用学期起止。'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plan_add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('plan_name')), '2026秋');
    await tester.enterText(find.byKey(const Key('plan_start')), '20260901');
    await tester.enterText(find.byKey(const Key('plan_end')), '20270115');
    await tester.tap(find.byKey(const Key('plan_save')));
    await tester.pumpAndSettle();

    // 起止日期经过掩码格式化，落库前已是 yyyy-MM-dd。
    expect(find.text('2026秋'), findsOneWidget);
    expect(find.text('2026-09-01 ~ 2027-01-15'), findsOneWidget);
    expect(settings.semesterPlans.single.name, '2026秋');
    expect(settings.semesterPlans.single.start, '2026-09-01');
  });

  testWidgets('新建课程时自动选中当前日期命中的学期方案', (WidgetTester tester) async {
    final now = DateTime.now();
    final start = dateKey(now.subtract(const Duration(days: 30)));
    final end = dateKey(now.add(const Duration(days: 30)));

    final settings = SettingsService.inMemory();
    await settings.saveSemesterPlans([
      SemesterPlan(id: 'p1', name: '本学期', start: start, end: end),
    ]);

    await tester.pumpWidget(buildApp(db: FakeDbService(), settings: settings));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程'));
    await tester.pumpAndSettle();

    // 学期起止被方案自动填上，不用手打。
    final startField = tester.widget<TextField>(
      find.byKey(const Key('input_semester_start')),
    );
    final endField = tester.widget<TextField>(
      find.byKey(const Key('input_semester_end')),
    );
    expect(startField.controller!.text, start);
    expect(endField.controller!.text, end);
  });

  testWidgets('我的页能进作息表，改完某节时间会存下来', (WidgetTester tester) async {
    final settings = SettingsService.inMemory();
    await tester.pumpWidget(buildApp(db: FakeDbService(), settings: settings));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    final entry = find.byKey(const Key('settings_period_table'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    // 默认是汕大作息，第 3 节 10:00–10:45。
    expect(find.text('作息表'), findsOneWidget);
    expect(find.text('第 3 节'), findsOneWidget);
    expect(find.text('10:00 – 10:45'), findsOneWidget);

    await tester.tap(find.byKey(const Key('period_row_3')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('period_start')), '10:10');
    await tester.enterText(find.byKey(const Key('period_end')), '10:55');
    await tester.tap(find.byKey(const Key('save_period')));
    await tester.pumpAndSettle();

    expect(settings.periodTable.byLabel('3')!.start, '10:10');
    expect(settings.periodTable.byLabel('3')!.end, '10:55');
    expect(find.text('10:10 – 10:55'), findsOneWidget);
  });

  testWidgets('作息表弹窗拒绝结束早于开始', (WidgetTester tester) async {
    final settings = SettingsService.inMemory();
    await tester.pumpWidget(buildApp(db: FakeDbService(), settings: settings));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('settings_period_table'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('period_row_1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('period_start')), '09:00');
    await tester.enterText(find.byKey(const Key('period_end')), '08:00');
    await tester.tap(find.byKey(const Key('save_period')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('period_message')), findsOneWidget);
    // 没被改掉，还是原来的 08:00–08:45。
    expect(settings.periodTable.byLabel('1')!.start, '08:00');
  });

  testWidgets('课表导入页空输入点解析给提示，不发请求', (WidgetTester tester) async {
    final settings = SettingsService.inMemory();
    await tester.pumpWidget(buildApp(db: FakeDbService(), settings: settings));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('settings_timetable_import'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.text('课表导入'), findsOneWidget);
    expect(find.textContaining('丢一个课表文件'), findsOneWidget);

    await tester.tap(find.byKey(const Key('timetable_parse')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('timetable_error')), findsOneWidget);
    expect(find.textContaining('先把课表文字粘进来'), findsOneWidget);
  });

  testWidgets('没有学期方案时，导入页提示先去建方案', (WidgetTester tester) async {
    await tester.pumpWidget(
      buildApp(
        db: FakeDbService(),
        settings: SettingsService.inMemory(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('settings_timetable_import'));
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.textContaining('还没有学期方案'), findsOneWidget);
  });
}
