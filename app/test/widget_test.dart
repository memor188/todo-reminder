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
import 'package:todo_app/screens/ai_chat_screen.dart';
import 'package:todo_app/services/db_service.dart';
import 'package:todo_app/services/notification_service.dart';
import 'package:todo_app/services/settings_service.dart';
import 'package:todo_app/theme.dart';

class FakeDbService extends DbService {
  AppData data = const AppData(courses: [], events: [], tasks: []);
  final List<Course> savedCourses = [];

  /// 编辑相关：测试里预置一条事件，记录 update / delete 是否被调用。
  EventItem? storedEvent;
  EventItem? updatedEvent;
  int? deletedEventId;

  /// 勾选相关：记录最后一次 setTaskDone / setEventDone 的参数。
  int? taskDoneId;
  bool? taskDoneValue;
  int? eventDoneId;
  bool? eventDoneValue;

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
    taskDoneId = id;
    taskDoneValue = done;
    // 2026-11-25 之前这里是直接把任务从 data 里删掉，模拟"勾完就不显示"。
    // 现在勾完要沉到已完成区，所以改成翻转 done 标记。
    data = AppData(
      courses: data.courses,
      events: data.events,
      tasks: [
        for (final task in data.tasks)
          if (task.id == id)
            TaskItem(
              id: task.id,
              title: task.title,
              dueDate: task.dueDate,
              dueTime: task.dueTime,
              location: task.location,
              note: task.note,
              done: done,
              remindBeforeMinutes: task.remindBeforeMinutes,
              priority: task.priority,
            )
          else
            task,
      ],
    );
  }

  @override
  Future<void> setEventDone(int id, {required bool done}) async {
    eventDoneId = id;
    eventDoneValue = done;
    data = AppData(
      courses: data.courses,
      events: [
        for (final event in data.events)
          if (event.id == id)
            EventItem(
              id: event.id,
              title: event.title,
              startAt: event.startAt,
              location: event.location,
              note: event.note,
              done: done,
              remindBeforeMinutes: event.remindBeforeMinutes,
              priority: event.priority,
            )
          else
            event,
      ],
      tasks: data.tasks,
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

  /// 走完一次勾选的完整粉尘序列（2026-11-26）。
  ///
  /// `_toggleEntry` 是异步的：先 await 落库 + _load()（两帧），再 setState
  /// flashKey。之后是四段 Timer 链 + shader 的 AnimationController。单纯
  /// `pumpAndSettle()` 在 Timer 之间那几帧没有 scheduled frame 时会提前返回，
  /// 所以按各段时长显式 pump，确保整条 2.3s 序列真的跑完。
  Future<void> pumpBurst(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 520)); // ① 散开 500
    await tester.pump(const Duration(milliseconds: 620)); // ② 收起 600
    await tester.pump(const Duration(milliseconds: 820)); // ③ 重组 800
    await tester.pump(const Duration(milliseconds: 420)); // ④ 高亮 400
    await tester.pumpAndSettle();
  }

  testWidgets('整体背景是象牙白，不是纯白', (WidgetTester tester) async {
    expect(ivoryBackground, isNot(Colors.white));
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme?.scaffoldBackgroundColor, ivoryBackground);
    expect(app.theme?.colorScheme.surface, ivoryBackground);
  });

  testWidgets('V1 首页有三 tab、添加按钮和空日程提示', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    expect(find.text('日程'), findsOneWidget);
    expect(find.text('课表'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.byKey(const Key('add_entry')), findsOneWidget);
    expect(find.text('这一天暂无日程'), findsOneWidget);
  });

  testWidgets('日程页左右滑动翻周，顶部不再写日期范围', (WidgetTester tester) async {
    // 视口换成 360 宽：拖 200px 就过了半页，PageView 才会翻页。
    useTallScreen(tester);
    final now = DateTime.now();
    final monday = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));
    final nextMonday = monday.add(const Duration(days: 7));

    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    // 2026-11-22 用户要求：顶部那行「11月16日 - 11月22日」多余，删掉。
    expect(
      find.text('${monday.month}月${monday.day}日 - ${sunday.month}月${sunday.day}日'),
      findsNothing,
    );
    expect(find.byKey(const Key('prev_week')), findsNothing);
    expect(find.byKey(const Key('next_week')), findsNothing);
    expect(find.byKey(Key('week_${dateKey(monday)}')), findsOneWidget);
    // 日期范围行删了，但月份还得看得见（用户 2026-11-22 反馈）
    expect(
      find.descendant(
        of: find.byKey(Key('week_${dateKey(monday)}')),
        matching: find.text('${monday.month}月'),
      ),
      findsOneWidget,
    );

    // 往左滑 = 下一周
    await tester.drag(find.byKey(const Key('week_pager')), const Offset(-200, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('week_${dateKey(nextMonday)}')), findsOneWidget);

    // 往右滑 = 回到本周
    await tester.drag(find.byKey(const Key('week_pager')), const Offset(200, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('week_${dateKey(monday)}')), findsOneWidget);
  });

  testWidgets('课表 tab 显示周网格（箭头已删，靠滑动翻周）', (WidgetTester tester) async {
    final now = DateTime.now();
    final monday = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));

    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tt_week_pager')), findsOneWidget);
    expect(find.byKey(Key('tt_week_${dateKey(monday)}')), findsOneWidget);
    // 顶部的日期范围和左右箭头已按用户要求删掉
    expect(find.byKey(const Key('tt_prev_week')), findsNothing);
    expect(find.byKey(const Key('tt_next_week')), findsNothing);
    expect(
      find.text('${monday.month}月${monday.day}日 - ${sunday.month}月${sunday.day}日'),
      findsNothing,
    );
    // 表头是单字周几（参考图样式），不再是「周一」
    expect(find.text('一'), findsWidgets);
    expect(find.text('日'), findsWidgets);
    // 左栏默认每两小时一个整点（2026-11-23）
    expect(find.text('8:00'), findsOneWidget);
    expect(find.text('10:00'), findsOneWidget);
    expect(find.text('08:45'), findsNothing);
  });

  testWidgets('课表左栏刻度可一键切换：整点 ↔ 节次', (WidgetTester tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();

    // 默认整点，按钮显示「时」
    expect(find.byKey(const Key('tt_toggle_ticks')), findsOneWidget);
    expect(find.text('时'), findsOneWidget);
    expect(find.text('8:00'), findsOneWidget);

    // 点一下 → 节次模式：出现起止时刻，整点消失
    await tester.tap(find.byKey(const Key('tt_toggle_ticks')));
    await tester.pumpAndSettle();
    expect(find.text('节'), findsOneWidget);
    expect(find.text('08:00'), findsOneWidget);
    expect(find.text('08:45'), findsOneWidget);
    expect(find.text('8:00'), findsNothing);

    // 再点一下 → 回到整点
    await tester.tap(find.byKey(const Key('tt_toggle_ticks')));
    await tester.pumpAndSettle();
    expect(find.text('时'), findsOneWidget);
    expect(find.text('8:00'), findsOneWidget);
    expect(find.text('08:45'), findsNothing);
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

    await tester.pumpWidget(buildApp(db: FakeDbService()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('tt_week_${dateKey(monday)}')), findsOneWidget);

    // 往左滑 = 下一周
    await tester.drag(
      find.byKey(const Key('tt_week_pager')),
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(Key('tt_week_${dateKey(nextMonday)}')), findsOneWidget);

    // 翻到别的周时右边会飘出「回到本周」
    expect(find.byKey(const Key('tt_back_to_this_week')), findsOneWidget);

    // 往右滑 = 回到本周
    await tester.drag(
      find.byKey(const Key('tt_week_pager')),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(Key('tt_week_${dateKey(monday)}')), findsOneWidget);
    expect(find.byKey(const Key('tt_back_to_this_week')), findsNothing);
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

  // 2026-11-23：课程录入页以前没有「提前提醒」，现在要和事件/任务一样能选，
  // 并且真的写进 Course 字段（否则排程还是写死的 10 分钟）。
  testWidgets('课程录入页能选提前提醒并落库', (WidgetTester tester) async {
    useTallScreen(tester);
    final db = FakeDbService();
    await tester.pumpWidget(buildApp(db: db));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程'));
    await tester.pumpAndSettle();

    expect(find.text('提前提醒'), findsOneWidget);
    await tester.ensureVisible(find.text('提前提醒'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提前提醒'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提前 30 分钟').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('input_title')), '数据结构');
    await tester.ensureVisible(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_entry')));
    await tester.pumpAndSettle();

    expect(db.savedCourses, hasLength(1));
    expect(db.savedCourses.single.remindBeforeMinutes, 30);
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

  testWidgets('AI 页选图按钮：模型不支持识图时拦截，不弹文件选择器',
      (WidgetTester tester) async {
    useTallScreen(tester);
    // 直接构造 AI 页，settings 不被导航层重建覆盖。
    // 官方域名 + 非 flash 模型 = 必被 _visionBlockedReason 拦下。
    final settings = SettingsService.inMemory(
      baseUrl: 'https://api.deepseek.com',
      apiKey: 'sk-test',
      model: 'deepseek-chat',
    );
    await tester.pumpWidget(MaterialApp(
      home: AiChatScreen(
        settings: settings,
        db: FakeDbService(),
        notifications: NotificationService(),
        // 若拦截失效就会调它；用它证明"没弹文件选择器"。
        pickImage: () async => throw StateError('不该读图片'),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ai_pick_image')));
    await tester.pumpAndSettle();

    // 拦截生效时不会调 pickImage（它会抛 StateError 让测试失败）。
    // 消息文字在底部 ListView 里、视口未必展开，所以断言行为而非渲染文本。
    expect(tester.takeException(), isNull);
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

  testWidgets('任务勾选后沉到已完成区', (WidgetTester tester) async {
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
    // 还没勾，不该有已完成区。
    expect(find.byKey(const Key('section_done')), findsNothing);

    await tester.tap(find.byKey(const Key('toggle_task_1')));
    await pumpBurst(tester);

    // 2026-11-25 过期分区改版：勾完不再从列表消失，而是沉到「已完成」区
    // （灰着、带删除线），否则用户看不出「做完了」和「错过了」的区别。
    expect(find.byKey(const Key('section_done')), findsOneWidget);
    expect(find.text('取快递'), findsOneWidget);
    expect(db.taskDoneId, 1);
    expect(db.taskDoneValue, isTrue);
  });

  testWidgets('已完成刚好 5 条时不出现折叠控件', (WidgetTester tester) async {
    final today = dateKey(DateTime.now());
    final db = FakeDbService();
    db.data = AppData(
      courses: const [],
      events: const [],
      tasks: [
        for (var i = 1; i <= 5; i++)
          TaskItem(id: i, title: '任务$i', dueDate: today, done: true),
      ],
    );
    await tester.pumpWidget(buildApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('day_$today')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('section_done')), findsOneWidget);
    expect(find.byKey(const Key('done_fold')), findsNothing);
    for (var i = 1; i <= 5; i++) {
      expect(find.text('任务$i'), findsOneWidget);
    }
  });

  testWidgets('已完成 6 条默认折叠最近 5 条，展开后全显示', (WidgetTester tester) async {
    final today = dateKey(DateTime.now());
    final db = FakeDbService();
    db.data = AppData(
      courses: const [],
      events: const [],
      tasks: [
        for (var i = 1; i <= 6; i++)
          TaskItem(id: i, title: '任务$i', dueDate: today, done: true),
      ],
    );
    await tester.pumpWidget(buildApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('day_$today')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('done_fold')), findsOneWidget);
    expect(find.text('展开更早的 1 条'), findsOneWidget);
    // 区内是正序（任务1 最早），默认折叠保留**最近** 5 条，
    // 所以最早的「任务1」被收起来 —— 这样刚勾完的那条永远看得见。
    expect(find.text('任务1'), findsNothing);

    await tester.tap(find.byKey(const Key('done_fold')));
    await tester.pumpAndSettle();
    expect(find.text('任务1'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);
  });

  testWidgets('勾选是散完再滑动：散开阶段下方不动，收起阶段才补位',
      (WidgetTester tester) async {
    // 用户看过视频后定的新时序（2026-11-25）：勾完先原地碎成粉尘飞散，
    // 这 500ms 下方**纹丝不动**；散完了卡片高度才收起、下方滑上来补位。
    // 旧行为是勾选瞬间就补位，用户原话「消失后立刻补位，看起来好难受」。
    final today = dateKey(DateTime.now());
    final db = FakeDbService();
    db.data = AppData(
      courses: const [],
      events: const [],
      tasks: [
        TaskItem(id: 1, title: '任务一', dueDate: today),
        TaskItem(id: 2, title: '任务二', dueDate: today),
        TaskItem(id: 3, title: '任务三', dueDate: today),
      ],
    );
    await tester.pumpWidget(buildApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('day_$today')));
    await tester.pumpAndSettle();

    final before = tester.getTopLeft(find.byKey(const Key('tile_task_2'))).dy;
    final goneHeight = tester
        .getSize(find.byKey(const Key('tile_task_1')))
        .height;

    await tester.tap(find.byKey(const Key('toggle_task_1')));
    await tester.pump();
    await tester.pump(); // 落库 + 重载两帧，动画从 0 起步

    // ① 散开阶段推到 250ms（总长 500ms）：下方那条必须还没动。
    await tester.pump(const Duration(milliseconds: 250));
    final duringDissipate =
        tester.getTopLeft(find.byKey(const Key('tile_task_2'))).dy;
    expect(duringDissipate, moreOrLessEquals(before, epsilon: 1),
        reason: '散开阶段下方应当纹丝不动，不能边散边滑');

    // 越过 500ms：散开 Timer 触发，这一帧才创建 removeItem 的收起动画。
    // 必须单独再 pump 才能让它推进 —— 挤在同一大步里读到的还是起始位置。
    await tester.pump(const Duration(milliseconds: 260));
    // ② 收起阶段推进到中段（700ms 总长的约一半）。
    await tester.pump(const Duration(milliseconds: 350));
    final duringCollapse =
        tester.getTopLeft(find.byKey(const Key('tile_task_2'))).dy;

    // 收起动画走完，下方条目到位。
    await tester.pump(const Duration(milliseconds: 400));
    final after = tester.getTopLeft(find.byKey(const Key('tile_task_2'))).dy;

    expect(after, lessThan(before), reason: '最终应当向上让位');
    expect(duringCollapse, lessThan(before),
        reason: '收起中途就该开始动，不能等到最后才跳');
    expect(duringCollapse, greaterThan(after),
        reason: '收起中途还没到位 —— 到位了就是瞬移');
    // 让位的距离正好等于消失那一行的高度。
    expect(before - after, closeTo(goneHeight, 4));
    expect(after, moreOrLessEquals(before - goneHeight, epsilon: 4));
  });

  testWidgets('切日期不播动画，直接换成那一天', (WidgetTester tester) async {
    // 换日期是整页换内容，一次动十几条更乱，所以列表实例按日期重建。
    final now = DateTime.now();
    final today = dateKey(now);
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final other = dateKey(monday);
    final db = FakeDbService();
    db.data = AppData(
      courses: const [],
      events: const [],
      tasks: [TaskItem(id: 1, title: '今天的任务', dueDate: today)],
    );
    await tester.pumpWidget(buildApp(db: db));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('day_$today')));
    await tester.pumpAndSettle();
    expect(find.text('今天的任务'), findsOneWidget);

    if (other != today) {
      await tester.tap(find.byKey(Key('day_$other')));
      await tester.pump();
      // 只推一帧：没有残留动画，内容已经整页换掉了。
      expect(find.text('今天的任务'), findsNothing);
      await tester.pumpAndSettle();
    }
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
