import 'dart:convert';

import 'package:http/http.dart' as http;

enum DraftType { event, task, course }

/// AI 生成的待办草稿：确认前只存在内存里，绝不直接入库。
class AiDraft {
  const AiDraft({
    required this.type,
    required this.title,
    this.date,
    this.time,
    this.endTime,
    this.dayOfWeek,
    this.location,
    this.note,
    this.raw,
  });

  final DraftType type;
  final String title;
  final String? date; // yyyy-MM-dd
  final String? time; // HH:mm
  final String? endTime;
  final int? dayOfWeek;
  final String? location;
  final String? note;
  final Map<String, dynamic>? raw;
}

class AiException implements Exception {
  const AiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// OpenAI 兼容的 Chat Completions 客户端（DeepSeek 等）。
class AiService {
  AiService({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    http.Client? client,
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now;

  final String baseUrl;
  final String apiKey;
  final String model;
  final http.Client _client;
  final DateTime Function() _now;

  /// 提示词定稿（2026-11-21）。三条硬规则来自真机讨论：
  /// 1. 已过的星期说法取"下一次出现"（今天周六说"周五"→ 下周五）；
  /// 2. 支持一句话多件事，返回 items 数组；
  /// 3. 只说日期没说钟点时 time 必须为 null，由 App 侧兜底当天 09:00 提醒。
  ///
  /// 用 {"items": [...]} 包裹而不是裸数组：OpenAI 兼容的 json_object 模式
  /// 要求顶层是对象，返回裸数组会被服务端拒绝。
  static const String systemPrompt = '''
你是待办解析助手。今天是 {TODAY}（星期{WEEKDAY}），当前时间 {HHMM}。

用户会用中文口语描述要办的事，可能一次说多件。先做时间换算，再判断类型，
最后只输出一个 JSON 对象，不要解释、不要 markdown 代码块。

时间换算：
1. 「周五」「周三」指下一次出现的那个星期几（含今天）；本周那天已过就算下一周。
2. 「下周三」= 下一个自然周的周三，不是 7 天后。
3. 「12.03」「12/3」按 月.日 理解 = 12 月 3 日；今年已过就算明年。
4. 「明天」「后天」按今天递推。
5. 只给日期没给钟点，time 填 null，不要编造。

类型：
- event：到点必须在那 —— 考试、讲座、会议、面试、火车航班。
- task：当天做完即可 —— 写作业、取快递、交材料、买东西。
- course：每周固定上课 —— 填 day_of_week 与 time/end_time，date 填首次上课日。
  day_of_week 必须是数字 1-7（周一=1，周日=7），不要写「周一」这种文字。

字段：
- title 保留用户原词或活动全称（可含期次、专场），去掉时间地点、emoji 和口号，不加「参加/去/完成」，不翻译。
- location 照抄原文，没有则 null。
- note 放额外要求（带计算器、开卷、提前签到），没有则 null。
- 不确定的字段一律 null，不要猜。

长文本：
用户可能直接粘贴一整段活动通知（带 emoji、报名链接、口号）。只提取这件事本身的时间、
地点和名称；链接、口号、报名步骤不要写进 title，有用的要求放 note。

输出格式（items 按用户提到的顺序排列，几件就几个）：
{"items":[{"type":"event","title":"...","date":"yyyy-MM-dd","time":"HH:mm","end_time":null,"day_of_week":null,"location":"...","note":null}]}
''';

  Uri get _endpoint {
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$normalized/v1/chat/completions');
  }

  Future<List<AiDraft>> parse(String userText) async {
    if (apiKey.trim().isEmpty) {
      throw const AiException('请先在「我的」页填写 API key');
    }
    final now = _now();
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final today =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final hhmm =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    final system = systemPrompt
        .replaceAll('{TODAY}', today)
        .replaceAll('{WEEKDAY}', weekdays[now.weekday - 1])
        .replaceAll('{HHMM}', hhmm);

    final response = await _client.post(
      _endpoint,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': model,
        'temperature': 0,
        'response_format': {'type': 'json_object'},
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': userText},
        ],
      }),
    );

    if (response.statusCode != 200) {
      throw AiException('AI 请求失败（${response.statusCode}）：${response.body}');
    }
    try {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final content = decoded['choices']![0]['message']['content'] as String;
      return _draftsFromPayload(jsonDecode(content));
    } on AiException {
      rethrow;
    } catch (e) {
      throw AiException('AI 返回格式无法解析：$e');
    }
  }

  /// 兼容三种返回形态：{"items":[...]}（约定）、裸数组、单个对象。
  List<AiDraft> _draftsFromPayload(Object? payload) {
    final List<Object?> rawItems;
    if (payload is Map<String, dynamic>) {
      final items = payload['items'];
      if (items is List) {
        rawItems = items;
      } else if (payload.containsKey('title')) {
        rawItems = [payload];
      } else {
        throw const AiException('AI 返回缺少 items 列表');
      }
    } else if (payload is List) {
      rawItems = payload;
    } else {
      throw const AiException('AI 返回格式无法解析');
    }

    final drafts = <AiDraft>[];
    for (final item in rawItems) {
      if (item is! Map<String, dynamic>) continue;
      final draft = _draftFromJson(item);
      if (draft != null) drafts.add(draft);
    }
    if (drafts.isEmpty) {
      throw const AiException('AI 没有解析出任何待办');
    }
    return drafts;
  }

  /// 模型有时把 day_of_week 写成「周一」而不是 1，这里两种都接。
  /// 真机实测（2026-11-21）：「每周一早上八点高数」返回了 "周一"，
  /// 只认数字会退化成"今天"，课程直接排错天。
  static int? parseDayOfWeek(Object? raw) {
    if (raw is num) {
      final value = raw.toInt();
      return (value >= 1 && value <= 7) ? value : null;
    }
    if (raw is String) {
      final text = raw.trim();
      final asInt = int.tryParse(text);
      if (asInt != null && asInt >= 1 && asInt <= 7) return asInt;
      const names = ['一', '二', '三', '四', '五', '六', '日'];
      for (var i = 0; i < names.length; i++) {
        if (text.contains(names[i])) return i + 1;
      }
      if (text.contains('天')) return 7; // 周天 / 星期天
    }
    return null;
  }

  /// 缺标题的条目直接跳过，不让一条脏数据拖垮整批。
  AiDraft? _draftFromJson(Map<String, dynamic> json) {
    final rawType = (json['type'] as String?)?.toLowerCase();
    final type = switch (rawType) {
      'course' => DraftType.course,
      'task' => DraftType.task,
      _ => DraftType.event,
    };
    final title = (json['title'] as String?)?.trim();
    if (title == null || title.isEmpty) return null;
    return AiDraft(
      type: type,
      title: title,
      date: json['date'] as String?,
      time: json['time'] as String?,
      endTime: json['end_time'] as String?,
      dayOfWeek: parseDayOfWeek(json['day_of_week']),
      location: json['location'] as String?,
      note: json['note'] as String?,
      raw: json,
    );
  }
}
