import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:todo_app/models/period_table.dart';
import 'package:todo_app/services/ai_service.dart';

/// 课表导入：AI 只负责把文字拆成「周几 + 第几节」，
/// 节次换算成钟点由本机作息表做。这里盯住这条分工有没有被执行对。
void main() {
  http.Request? captured;
  final fixedNow = DateTime(2026, 11, 22, 14, 50);
  const table = PeriodTable.shantouDefault;

  AiService serviceFor(http.Client client, {String apiKey = 'sk-test'}) =>
      AiService(
        baseUrl: 'https://api.example.com/',
        apiKey: apiKey,
        model: 'test-model',
        client: client,
        now: () => fixedNow,
      );

  http.Response okResponse(Object content) => http.Response(
    jsonEncode({
      'choices': [
        {
          'message': {'content': jsonEncode(content)},
        },
      ],
    }),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  /// 造一个只回一条课程的 client。
  AiService serviceReturning(Map<String, Object?> course) => serviceFor(
    MockClient((request) async {
      captured = request;
      return okResponse({
        'courses': [course],
      });
    }),
  );

  group('节次换算是本机做的', () {
    test('period "3-5" → 10:00–12:35', () async {
      final drafts = await serviceReturning({
        'title': '信号与系统',
        'day_of_week': 2,
        'period': '3-5',
        'location': 'E302',
      }).parseTimetable('随便的课表文本', periodTable: table);

      final draft = drafts.single;
      expect(draft.startTime, '10:00');
      expect(draft.endTime, '12:35');
      expect(draft.dayOfWeek, 2);
      expect(draft.location, 'E302');
      expect(draft.resolved, isTrue);
      expect(draft.unresolvedReason, isNull);
    });

    test('AI 照抄原文的 "345" 也能换算', () async {
      final drafts = await serviceReturning({
        'title': '电路',
        'day_of_week': 1,
        'period': '345',
      }).parseTimetable('周一345节 电路', periodTable: table);

      expect(drafts.single.startTime, '10:00');
      expect(drafts.single.endTime, '12:35');
    });

    test('晚上 A-C 节 → 19:20–21:55', () async {
      final drafts = await serviceReturning({
        'title': '晚课',
        'day_of_week': 4,
        'period': 'A-C',
      }).parseTimetable('周四晚上', periodTable: table);

      expect(drafts.single.startTime, '19:20');
      expect(drafts.single.endTime, '21:55');
    });

    test('AI 自作主张给的钟点被忽略，以作息表为准', () async {
      // 节次是原文里客观存在的，作息表算出来一定对；
      // AI 顺手算的钟点可能凭空多出 5 分钟。
      final drafts = await serviceReturning({
        'title': '高数',
        'day_of_week': 1,
        'period': '1-2',
        'time': '08:05',
        'end_time': '09:45',
      }).parseTimetable('周一12节高数', periodTable: table);

      expect(drafts.single.startTime, '08:00');
      expect(drafts.single.endTime, '09:40');
    });

    test('作息表里没有的节次 → 标记未解析，不当成能入库', () async {
      final drafts = await serviceReturning({
        'title': '神秘课',
        'day_of_week': 3,
        'period': 'D-D',
      }).parseTimetable('周三D节', periodTable: table);

      final draft = drafts.single;
      expect(draft.resolved, isFalse);
      expect(draft.unresolvedReason, contains('不在作息表里'));
      expect(draft.timeLabel, '第 D-D 节');
    });

    test('节次认不出、但原文给了钟点 → 仍可入库', () async {
      final drafts = await serviceReturning({
        'title': '实验',
        'day_of_week': 5,
        'period': 'X',
        'time': '14:00',
        'end_time': '15:40',
      }).parseTimetable('周五实验', periodTable: table);

      expect(drafts.single.resolved, isTrue);
      expect(drafts.single.startTime, '14:00');
      expect(drafts.single.unresolvedReason, isNull);
    });
  });

  group('脏数据不落库', () {
    test('不知道周几的课程被丢弃', () async {
      final service = serviceFor(
        MockClient((request) async {
          return okResponse({
            'courses': [
              {'title': '有周几的', 'day_of_week': 1, 'period': '1-2'},
              {'title': '没周几的', 'period': '1-2'},
            ],
          });
        }),
      );

      final drafts = await service.parseTimetable('混着', periodTable: table);
      expect(drafts.length, 1);
      expect(drafts.single.title, '有周几的');
    });

    test('缺标题被丢弃', () async {
      final service = serviceFor(
        MockClient((request) async {
          return okResponse({
            'courses': [
              {'title': '  ', 'day_of_week': 1, 'period': '1-2'},
              {'title': '正常', 'day_of_week': 2, 'period': '3-4'},
            ],
          });
        }),
      );

      final drafts = await service.parseTimetable('x', periodTable: table);
      expect(drafts.single.title, '正常');
    });

    test('结束时间早于开始时间 → 标记未解析', () async {
      final drafts = await serviceReturning({
        'title': '时间写反的',
        'day_of_week': 1,
        'time': '10:00',
        'end_time': '09:00',
      }).parseTimetable('x', periodTable: table);

      expect(drafts.single.resolved, isFalse);
      expect(drafts.single.unresolvedReason, contains('早于'));
    });

    test('一条都解析不出时抛可读异常', () async {
      final service = serviceFor(
        MockClient((request) async {
          return okResponse({'courses': []});
        }),
      );

      expect(
        () => service.parseTimetable('空白', periodTable: table),
        throwsA(
          isA<AiException>().having(
            (e) => e.message,
            'message',
            contains('没有解析出任何课程'),
          ),
        ),
      );
    });
  });

  group('字段清洗', () {
    test('星期写成「周三」也能认', () async {
      final drafts = await serviceReturning({
        'title': '大学物理',
        'day_of_week': '周三',
        'period': '6-7',
      }).parseTimetable('x', periodTable: table);

      expect(drafts.single.dayOfWeek, 3);
    });

    test('单双周从文字里认', () async {
      final singles = await serviceReturning({
        'title': '单周课',
        'day_of_week': 1,
        'period': '1-2',
        'week_parity': '单周',
      }).parseTimetable('x', periodTable: table);
      expect(singles.single.weekParity, 1);

      final doubles = await serviceReturning({
        'title': '双周课',
        'day_of_week': 1,
        'period': '1-2',
        'week_parity': 2,
      }).parseTimetable('x', periodTable: table);
      expect(doubles.single.weekParity, 2);
    });

    test('空字符串地点归 null，不留空串', () async {
      final drafts = await serviceReturning({
        'title': '课',
        'day_of_week': 1,
        'period': '1',
        'location': '   ',
        'note': '',
      }).parseTimetable('x', periodTable: table);

      expect(drafts.single.location, isNull);
      expect(drafts.single.note, isNull);
    });

    test('全角钟点被归一化', () async {
      final drafts = await serviceReturning({
        'title': '课',
        'day_of_week': 1,
        'time': '０８：００',
        'end_time': '09:40',
      }).parseTimetable('x', periodTable: table);

      expect(drafts.single.startTime, '08:00');
    });
  });

  group('提示词把关键约定交给了模型', () {
    test('包含整张作息表、大节对应、以及 "345" 的记号说明', () async {
      await serviceReturning({
        'title': '课',
        'day_of_week': 1,
        'period': '1',
      }).parseTimetable('x', periodTable: table);

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      final system =
          (body['messages'] as List).first['content'] as String;

      expect(system, contains('第 3 节 10:00–10:45'));
      expect(system, contains('第 C 节 21:10–21:55'));
      expect(system, contains('二=3-5节'));
      expect(system, contains('"345" 表示第 3~5 节'));
      expect(system, contains('2026-11-22'));
      // 一门课上多次要拆开，否则第二次上课会丢。
      expect(system, contains('每次单独一条'));
    });
  });

  group('前置校验', () {
    test('没填 key 时不发请求', () async {
      var called = false;
      final service = serviceFor(
        MockClient((request) async {
          called = true;
          return okResponse({'courses': []});
        }),
        apiKey: '',
      );

      expect(
        () => service.parseTimetable('x', periodTable: table),
        throwsA(isA<AiException>()),
      );
      expect(called, isFalse);
    });

    test('作息表为空时直接拒绝，不浪费一次请求', () async {
      var called = false;
      final service = serviceFor(
        MockClient((request) async {
          called = true;
          return okResponse({'courses': []});
        }),
      );

      expect(
        () => service.parseTimetable('x', periodTable: const PeriodTable([])),
        throwsA(
          isA<AiException>().having(
            (e) => e.message,
            'message',
            contains('作息表是空的'),
          ),
        ),
      );
      expect(called, isFalse);
    });
  });
}
