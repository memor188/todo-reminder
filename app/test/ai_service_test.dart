import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/services/ai_service.dart';

void main() {
  http.Request? captured;
  // 测试固定"现在"为 2026-11-21（星期六）21:19，星期名由日期推导，避免手算写错。
  final fixedNow = DateTime(2026, 11, 21, 21, 19);
  const weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];

  AiService serviceFor(http.Client client, {String apiKey = 'sk-test'}) =>
      AiService(
        baseUrl: 'https://api.example.com/',
        apiKey: apiKey,
        model: 'test-model',
        client: client,
        now: () => fixedNow,
      );

  /// 构造一个成功响应，content 是模型返回的 JSON 文本。
  http.Response okResponse(Object content) => http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {'content': jsonEncode(content)},
        },
      ],
    }),
    200,
    // 不显式声明 charset 时 http.Response 按 latin1 编码，中文会直接抛异常。
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  group('AI 草稿解析', () {
    test('请求带认证头、注入当前日期星期与时刻', () async {
      final client = MockClient((request) async {
        captured = request;
        return okResponse({
          'items': [
            {
              'type': 'event',
              'title': '考试',
              'date': '2026-11-27',
              'time': '17:00',
              'location': 'E栋104',
              'note': null,
            },
          ],
        });
      });

      await serviceFor(client).parse('周五17点E栋104考试');

      expect(
        captured!.url.toString(),
        'https://api.example.com/v1/chat/completions',
      );
      expect(captured!.headers['Authorization'], 'Bearer sk-test');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      final system = body['messages'][0]['content'] as String;
      expect(system, contains('2026-11-21'));
      expect(system, contains('星期${weekdayNames[fixedNow.weekday - 1]}'));
      expect(system, contains('21:19'));
      expect(body['response_format'], {'type': 'json_object'});
    });

    test('提示词含三条定稿规则：下一次出现 / 月.日 / 无钟点填 null', () async {
      final client = MockClient(
        (_) async => okResponse({
          'items': [
            {'type': 'task', 'title': '交作业', 'date': '2026-11-27'},
          ],
        }),
      );

      await serviceFor(client).parse('周五交作业');

      const prompt = AiService.systemPrompt;
      expect(prompt, contains('下一次出现的那个星期几'));
      expect(prompt, contains('月.日'));
      expect(prompt, contains('time 填 null'));
      expect(prompt, contains('items'));
    });

    test('一句多件事解析成多条草稿，顺序保持', () async {
      final client = MockClient(
        (_) async => okResponse({
          'items': [
            {
              'type': 'event',
              'title': '考试',
              'date': '2026-11-27',
              'time': '17:00',
              'location': 'E栋104',
            },
            {
              'type': 'task',
              'title': '交作业',
              'date': '2026-11-29',
              'time': null,
            },
          ],
        }),
      );

      final drafts = await serviceFor(client).parse('周五17点E栋104考试，周日交作业');

      expect(drafts, hasLength(2));
      expect(drafts[0].type, DraftType.event);
      expect(drafts[0].title, '考试');
      expect(drafts[0].date, '2026-11-27');
      expect(drafts[0].time, '17:00');
      expect(drafts[0].location, 'E栋104');
      expect(drafts[1].type, DraftType.task);
      expect(drafts[1].time, isNull);
    });

    test('课程草稿带回 day_of_week 与结束时间', () async {
      final client = MockClient(
        (_) async => okResponse({
          'items': [
            {
              'type': 'course',
              'title': '高数',
              'date': '2026-11-23',
              'time': '08:00',
              'end_time': '09:40',
              'day_of_week': 1,
              'location': 'E104',
            },
          ],
        }),
      );

      final drafts = await serviceFor(client).parse('每周一早上八点高数');

      expect(drafts.single.type, DraftType.course);
      expect(drafts.single.dayOfWeek, 1);
      expect(drafts.single.endTime, '09:40');
    });

    test('兼容模型返回裸数组', () async {
      final client = MockClient(
        (_) async => okResponse([
          {
            'type': 'event',
            'title': '讲座',
            'date': '2026-12-03',
            'time': '19:00',
          },
        ]),
      );

      final drafts = await serviceFor(client).parse('12.03听讲座');
      expect(drafts.single.title, '讲座');
      expect(drafts.single.date, '2026-12-03');
    });

    test('兼容模型返回单个对象（不带 items 包裹）', () async {
      final client = MockClient(
        (_) async =>
            okResponse({'type': 'task', 'title': '取快递', 'date': '2026-11-22'}),
      );

      final drafts = await serviceFor(client).parse('明天取快递');
      expect(drafts.single.title, '取快递');
    });

    test('缺标题的条目被跳过，不拖垮整批', () async {
      final client = MockClient(
        (_) async => okResponse({
          'items': [
            {'type': 'event', 'title': '', 'date': '2026-11-27'},
            {'type': 'task', 'title': '交作业', 'date': '2026-11-29'},
          ],
        }),
      );

      final drafts = await serviceFor(client).parse('周五考试，周日交作业');
      expect(drafts, hasLength(1));
      expect(drafts.single.title, '交作业');
    });

    test('API key 为空时不发请求直接报错', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      });
      expect(
        () => serviceFor(client, apiKey: '').parse('测试'),
        throwsA(isA<AiException>()),
      );
      expect(called, isFalse);
    });

    test('AI 返回非 JSON 时抛可读异常', () async {
      final client = MockClient((_) async => http.Response('not json', 200));
      expect(() => serviceFor(client).parse('测试'), throwsA(isA<AiException>()));
    });

    test('items 为空数组时抛可读异常', () async {
      final client = MockClient((_) async => okResponse({'items': []}));
      expect(() => serviceFor(client).parse('测试'), throwsA(isA<AiException>()));
    });

    test('非 200 状态码抛异常', () async {
      final client = MockClient((_) async => http.Response('no key', 401));
      expect(() => serviceFor(client).parse('测试'), throwsA(isA<AiException>()));
    });
  });
}
