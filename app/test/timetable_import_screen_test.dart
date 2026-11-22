import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:todo_app/models/course.dart';
import 'package:todo_app/models/semester_plan.dart';
import 'package:todo_app/screens/timetable_import_screen.dart';
import 'package:todo_app/services/ai_service.dart';
import 'package:todo_app/services/db_service.dart';
import 'package:todo_app/services/settings_service.dart';

/// 导入页的三条入口：粘贴文字 / 丢文件 / 丢截图。
///
/// 文件选择器走平台通道，测试里调不动，所以 widget 暴露了 [pickFile] 注入点；
/// AI 请求则用 MockClient 顶替，顺便检查多模态请求体到底长什么样。
class _FakeDb extends DbService {
  final List<Course> saved = [];

  @override
  Future<AppData> queryAll() async =>
      const AppData(courses: [], events: [], tasks: []);

  @override
  Future<int> insertCourse(Course item) async {
    saved.add(item);
    return saved.length;
  }
}

void main() {
  // 夹具含本人学号与姓名，已排除出 git；本机上存在时这些用例必须全跑。
  final fixture = File('test/fixtures/timetable.xls');
  final hasFixture = fixture.existsSync();

  late Uint8List xlsBytes;

  setUpAll(() {
    if (!hasFixture) return;
    xlsBytes = fixture.readAsBytesSync();
  });

  /// 真机竖屏尺寸。导入页顶部控件不少，800×600 的默认视口容易挤到溢出。
  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 3840);
    tester.view.devicePixelRatio = 3.0; // → 360 × 1280 逻辑像素
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<SettingsService> settingsWithPlan({
    String model = 'deepseek-flash',
    String baseUrl = 'https://api.deepseek.com',
  }) async {
    final settings = SettingsService.inMemory(
      baseUrl: baseUrl,
      apiKey: 'sk-test',
      model: model,
    );
    await settings.saveSemesterPlans(const [
      SemesterPlan(
        id: 'p1',
        name: '2026秋',
        start: '2026-09-07',
        end: '2027-01-15',
      ),
    ]);
    return settings;
  }

  Widget buildScreen({
    required _FakeDb db,
    required SettingsService settings,
    Future<PickedTimetableFile?> Function()? pickFile,
    AiService Function()? aiFactory,
  }) => MaterialApp(
    home: TimetableImportScreen(
      settings: settings,
      db: db,
      pickFile: pickFile,
      aiFactory: aiFactory,
    ),
  );

  http.Response okCourses(List<Map<String, Object?>> courses) => http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {
            'content': jsonEncode({'courses': courses}),
          },
        },
      ],
    }),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  testWidgets('丢一个 .xls 进来：本机解析、12 门课、预览带教师和周次', (tester) async {
    useTallScreen(tester);
    final db = _FakeDb();
    await tester.pumpWidget(
      buildScreen(
        db: db,
        settings: await settingsWithPlan(),
        pickFile: () async =>
            PickedTimetableFile(name: '学生个人课表.xls', bytes: xlsBytes),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('timetable_pick_file')));
    await tester.pumpAndSettle();

    final message = tester
        .widget<Text>(find.byKey(const Key('timetable_message')))
        .data!;
    expect(message, contains('12 门课'));
    // .xls 走的是本机解析，提示里要说清楚没联网
    expect(message, contains('没联网'));

    // 预览第一行：课程名 + 时间 + 地点 + 教师 + 周次（顺序与 .xls 里出现的一致）
    expect(find.text('习近平新时代中国特色社会主义思想概论'), findsOneWidget);
    final subtitle = tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(const Key('import_row_0')),
            matching: find.byType(Text),
          ).last,
        )
        .data!;
    expect(subtitle, contains('周四 08:00–09:40'));
    expect(subtitle, contains('东海岸-E教527'));
    expect(subtitle, contains('林嘉丽'));
    expect(subtitle, contains('4,6,8,10,12,14,16,18周'));
  }, skip: !hasFixture); // 缺夹具时跳过（夹具不入库）

  testWidgets('确认导入：教师、周次一起落库，学期起止来自方案', (tester) async {
    useTallScreen(tester);
    final db = _FakeDb();
    await tester.pumpWidget(
      buildScreen(
        db: db,
        settings: await settingsWithPlan(),
        pickFile: () async =>
            PickedTimetableFile(name: '课表.xls', bytes: xlsBytes),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timetable_pick_file')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('timetable_import')));
    await tester.pumpAndSettle();

    expect(db.saved.length, 12);
    expect(db.saved.every((course) => course.teacher != null), isTrue);
    expect(db.saved.every((course) => course.weeks != null), isTrue);
    expect(db.saved.first.semesterStart, '2026-09-07');
    expect(db.saved.first.semesterEnd, '2027-01-15');

    final linalg = db.saved.firstWhere((course) => course.title == '线性代数');
    expect(linalg.weeks, '3-18'); // 两段周次已合并
    expect(linalg.teacher, '陈哲');
  }, skip: !hasFixture); // 缺夹具时跳过（夹具不入库）

  testWidgets('丢一张截图进来：按多模态发请求，图片走 base64 内联', (tester) async {
    useTallScreen(tester);
    final db = _FakeDb();
    http.Request? captured;
    await tester.pumpWidget(
      buildScreen(
        db: db,
        settings: await settingsWithPlan(),
        pickFile: () async => PickedTimetableFile(
          name: '课表截图.png',
          bytes: Uint8List.fromList(const [1, 2, 3, 4, 5]),
        ),
        aiFactory: () => AiService(
          baseUrl: 'https://api.deepseek.com',
          apiKey: 'sk-test',
          model: 'deepseek-flash',
          client: MockClient((request) async {
            captured = request;
            return okCourses([
              {
                'title': '高等数学A',
                'day_of_week': 1,
                'period': '1-2',
                'location': 'E302',
                'teacher': '张三',
                'weeks': '3-18',
              },
            ]);
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('timetable_pick_file')));
    await tester.pumpAndSettle();

    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    final userContent =
        (body['messages'] as List)[1]['content'] as List<dynamic>;
    expect(userContent.first['type'], 'text');
    final imagePart = userContent[1] as Map<String, dynamic>;
    expect(imagePart['type'], 'image_url');
    expect(
      (imagePart['image_url'] as Map)['url'],
      startsWith('data:image/png;base64,'),
    );

    expect(find.text('高等数学A'), findsOneWidget);
    expect(find.byKey(const Key('timetable_message')), findsOneWidget);
  });

  testWidgets('模型不支持识图时，先提示换模型、不发请求', (tester) async {
    useTallScreen(tester);
    final db = _FakeDb();
    var called = false;
    await tester.pumpWidget(
      buildScreen(
        db: db,
        settings: await settingsWithPlan(model: 'deepseek-v4-pro'),
        pickFile: () async => PickedTimetableFile(
          name: '截图.jpg',
          bytes: Uint8List.fromList(const [9, 9, 9]),
        ),
        aiFactory: () => AiService(
          baseUrl: 'https://api.deepseek.com',
          apiKey: 'sk-test',
          model: 'deepseek-v4-pro',
          client: MockClient((request) async {
            called = true;
            return okCourses(const []);
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('timetable_pick_file')));
    await tester.pumpAndSettle();

    final error = tester
        .widget<Text>(find.byKey(const Key('timetable_error')))
        .data!;
    expect(error, contains('不能识图'));
    expect(error, contains('deepseek-flash'));
    expect(called, isFalse);
  });

  testWidgets('.xlsx 给出「另存为 .xls」的明确指引', (tester) async {
    useTallScreen(tester);
    final db = _FakeDb();
    await tester.pumpWidget(
      buildScreen(
        db: db,
        settings: await settingsWithPlan(),
        pickFile: () async => PickedTimetableFile(
          name: '课表.xlsx',
          bytes: Uint8List.fromList(const [0x50, 0x4B, 0x03, 0x04]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('timetable_pick_file')));
    await tester.pumpAndSettle();

    final error = tester
        .widget<Text>(find.byKey(const Key('timetable_error')))
        .data!;
    expect(error, contains('.xlsx'));
    expect(error, contains('另存为'));
  });

  testWidgets('CSV 文件读进输入框再交给 AI 解析', (tester) async {
    useTallScreen(tester);
    final db = _FakeDb();
    http.Request? captured;
    await tester.pumpWidget(
      buildScreen(
        db: db,
        settings: await settingsWithPlan(),
        pickFile: () async => PickedTimetableFile(
          name: '课表.csv',
          bytes: Uint8List.fromList(
            utf8.encode('星期一,1-2,高等数学,E302\n星期二,3-4,电路,E201'),
          ),
        ),
        aiFactory: () => AiService(
          baseUrl: 'https://api.deepseek.com',
          apiKey: 'sk-test',
          model: 'deepseek-flash',
          client: MockClient((request) async {
            captured = request;
            return okCourses([
              {'title': '高等数学', 'day_of_week': 1, 'period': '1-2'},
              {'title': '电路', 'day_of_week': 2, 'period': '3-4'},
            ]);
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('timetable_pick_file')));
    await tester.pumpAndSettle();

    // 读到的原文填进输入框，用户能看见 AI 到底吃了什么
    final field = tester.widget<TextField>(
      find.byKey(const Key('timetable_input')),
    );
    expect(field.controller!.text, contains('高等数学'));
    // 文本路径不带图片
    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect((body['messages'] as List)[1]['content'], isA<String>());
    expect(find.text('电路'), findsOneWidget);
  });
}
