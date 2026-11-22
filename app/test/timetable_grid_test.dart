import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/main.dart';
import 'package:todo_app/models/course.dart';
import 'package:todo_app/models/timeline.dart';
import 'package:todo_app/services/db_service.dart';
import 'package:todo_app/services/notification_service.dart';
import 'package:todo_app/services/settings_service.dart';
import 'package:todo_app/widgets/timeline_item.dart';

/// 课表网格改版（2026-11-22，按用户给的参考图）：
/// 左栏节次、按课名稳定取色、本周不上的课灰着标「非本周」。
class _FakeDb extends DbService {
  _FakeDb(this.courses);

  final List<Course> courses;

  @override
  Future<AppData> queryAll() async =>
      AppData(courses: courses, events: const [], tasks: const []);
}

void main() {
  DateTime monday() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return today.subtract(Duration(days: now.weekday - 1));
  }

  String d(DateTime value) => dateKey(value);

  Widget buildApp(List<Course> courses) => App(
    notifications: NotificationService(),
    permissionGranted: true,
    db: _FakeDb(courses),
    settings: SettingsService.inMemory(),
  );

  /// 视口换成真机竖屏：网格一页有 1000 多像素高，800×600 里只能看到一小截。
  void useTallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 3840);
    tester.view.devicePixelRatio = 3.0; // → 360 × 1280
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets('本周不上的课也画出来，灰着带「非本周」', (tester) async {
    useTallScreen(tester);
    final m = monday();
    // 让「本周」正好是第 4 周：学期从 3 周前开始
    final start = m.subtract(const Duration(days: 21));
    final end = m.add(const Duration(days: 140));

    await tester.pumpWidget(
      buildApp([
        Course(
          title: '本周的课',
          dayOfWeek: 1,
          startTime: '08:00',
          endTime: '09:40',
          location: 'E201',
          weeks: '4',
          semesterStart: d(start),
          semesterEnd: d(end),
        ),
        Course(
          title: '只在第一周的课',
          dayOfWeek: 1,
          startTime: '10:00',
          endTime: '11:40',
          location: 'E301',
          weeks: '1',
          semesterStart: d(start),
          semesterEnd: d(end),
        ),
      ]),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();

    // 两门都画出来
    expect(find.text('本周的课'), findsOneWidget);
    expect(find.text('只在第一周的课'), findsOneWidget);
    // 只有不上的那门带标签
    expect(find.text('非本周'), findsOneWidget);
  });

  testWidgets('地点按 @教室 显示，和参考图一致', (tester) async {
    useTallScreen(tester);
    final m = monday();
    await tester.pumpWidget(
      buildApp([
        Course(
          title: '线性代数',
          dayOfWeek: 1,
          startTime: '08:00',
          endTime: '09:40',
          location: '东海岸-E教201-阶梯',
          weeks: '1-18',
          semesterStart: d(m.subtract(const Duration(days: 21))),
          semesterEnd: d(m.add(const Duration(days: 140))),
        ),
      ]),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();

    expect(find.text('@东海岸-E教201-阶梯'), findsOneWidget);
  });

  testWidgets('翻到别的周会出现「回到本周」，点一下回本周', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(buildApp(const []));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();

    // 本周不显示
    expect(find.byKey(const Key('tt_back_to_this_week')), findsNothing);

    await tester.drag(
      find.byKey(const Key('tt_week_pager')),
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_back_to_this_week')), findsOneWidget);

    await tester.tap(find.byKey(const Key('tt_back_to_this_week')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tt_back_to_this_week')), findsNothing);
  });

  group('课程取色', () {
    TimelineEntry entry(String title, {String? colorHex}) => TimelineEntry(
      key: 'k_$title',
      sourceId: 1,
      type: EntryType.course,
      title: title,
      sortMinutes: 480,
      timeLabel: '08:00–09:40',
      colorHex: colorHex,
    );

    test('同一门课每次都是同一个颜色', () {
      expect(
        courseColorFor(entry('线性代数')),
        courseColorFor(entry('线性代数')),
      );
    });

    test('不同课名尽量分到不同颜色', () {
      final colors = {
        for (final title in [
          '线性代数',
          '微积分B-I',
          '习近平新时代中国特色社会主思想概论',
          'ELC1综合英语与沟通能力',
          '汕大整合思维',
        ])
          courseColorFor(entry(title)),
      };
      // 5 门课里至少分出 3 种颜色，不至于糊成一片
      expect(colors.length, greaterThanOrEqualTo(3));
    });

    test('显式指定的颜色优先（将来做手动配色用）', () {
      expect(
        courseColorFor(entry('任意课', colorHex: 'FF9800')),
        colorFromHex('FF9800'),
      );
    });
  });

  group('整屏配色统一分配', () {
    Course course(String title, {String? color}) => Course(
      title: title,
      dayOfWeek: 1,
      startTime: '08:00',
      endTime: '09:40',
      color: color,
      semesterStart: '2026-09-07',
      semesterEnd: '2027-01-17',
    );

    test('十门课十个色，一个不撞', () {
      final colors = assignCourseColors([
        for (final title in ['甲', '乙', '丙', '丁', '戊', '己', '庚', '辛', '壬', '癸'])
          course(title),
      ]);
      expect(colors.length, 10);
      expect(colors.values.toSet().length, 10);
    });

    test('超过十门才开始重复，且前十个仍然各不相同', () {
      final titles = [
        for (var i = 0; i < 14; i++) '课程$i',
      ];
      final colors = assignCourseColors(titles.map(course));
      expect(colors.length, 14);
      expect(colors.values.toSet().length, coursePalette.length);
    });

    test('用户设过颜色的课保留自己的色，也不被别的课抢走', () {
      final colors = assignCourseColors([
        course('指定色', color: 'FF5722'),
        course('普通课'),
      ]);
      expect(colors['指定色'], colorFromHex('FF5722'));
      expect(colors['普通课'], isNot(colorFromHex('FF5722')));
    });

    test('同名课（一周上两次）拿同一个色', () {
      final colors = assignCourseColors([course('高数'), course('高数')]);
      expect(colors.length, 1);
    });
  });
}
