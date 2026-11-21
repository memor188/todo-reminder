// V0 UI 测试：验证通知链路探针页面的关键控件存在与交互。
// 这些测试针对 V0 的真实 UI，不是模板 smoke test。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/main.dart';
import 'package:todo_app/services/notification_service.dart';

void main() {
  // 测试用的假服务：Flutter 插件在 test 环境没有平台实现，
  // 所以用一个遵循同一接口的替身来验 UI 逻辑，不碰真实通知通道。
  // 通过构造一个不调用插件的对象来避开平台通道——
  // 这里直接用真实单例但只测不触发调度路径的控件呈现。

  testWidgets('V0 页面显示所有关键控件', (WidgetTester tester) async {
    // 真实 NotificationService 单例在 test 环境未 init，但页面构建不调用插件。
    final service = NotificationService();
    await tester.pumpWidget(V0App(notifications: service, permissionGranted: true));

    expect(find.text('待办 App V0 · 通知链路验证'), findsOneWidget);
    expect(find.byKey(const Key('title_field')), findsOneWidget);
    expect(find.byKey(const Key('time_picker_tile')), findsOneWidget);
    expect(find.byKey(const Key('schedule_button')), findsOneWidget);
    expect(find.byKey(const Key('test_button')), findsOneWidget);
    expect(find.text('10 秒后测试（脚手架，V1 删除）'), findsOneWidget);
  });

  testWidgets('事项为空时点设置提醒给出提示，不崩溃', (WidgetTester tester) async {
    final service = NotificationService();
    await tester.pumpWidget(V0App(notifications: service, permissionGranted: true));

    await tester.tap(find.byKey(const Key('schedule_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('status_message')), findsOneWidget);
    expect(find.text('请先输入事项'), findsOneWidget);
  });

  testWidgets('事项为空时点 10 秒测试给出提示，不崩溃', (WidgetTester tester) async {
    final service = NotificationService();
    await tester.pumpWidget(V0App(notifications: service, permissionGranted: true));

    await tester.tap(find.byKey(const Key('test_button')));
    await tester.pumpAndSettle();

    expect(find.text('请先输入事项'), findsOneWidget);
  });

  testWidgets('权限未授予时显示明确警示（不静默失败）', (WidgetTester tester) async {
    final service = NotificationService();
    await tester.pumpWidget(V0App(notifications: service, permissionGranted: false));

    expect(
      find.textContaining('通知权限未授予'),
      findsOneWidget,
    );
  });

  testWidgets('输入事项后可点击设置提醒按钮', (WidgetTester tester) async {
    final service = NotificationService();
    await tester.pumpWidget(V0App(notifications: service, permissionGranted: true));

    await tester.enterText(find.byKey(const Key('title_field')), '测试提醒');
    await tester.pump();
    expect(find.text('测试提醒'), findsOneWidget);

    // 按钮此时应可点击（不抛异常）。真实调度需平台插件，在 widget 测试里
    // 用一个会抛 MissingPluginException 的调用验证错误分支被 UI 捕获为文案。
    await tester.tap(find.byKey(const Key('schedule_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('status_message')), findsOneWidget);
  });
}
