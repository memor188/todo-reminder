import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/period_table.dart';
import '../models/timeline.dart';

enum DraftType { event, task, course }

/// 课表导入的草稿：一门课的一次上课。
///
/// 和 [AiDraft] 分开是因为字段重心不同：课表要的是「周几 + 第几节」，
/// 待办要的是「哪天的几点」。混用一个类会让两边的校验互相牵制。
class AiCourseDraft {
  const AiCourseDraft({
    required this.title,
    required this.dayOfWeek,
    this.period,
    this.startTime,
    this.endTime,
    this.location,
    this.note,
    this.weekParity = 0,
    this.unresolvedReason,
    this.raw,
  });

  final String title;

  /// 1=周一 … 7=周日。
  final int dayOfWeek;

  /// 原文里的节次写法，如 '3-5'、'AB'。
  final String? period;

  /// 换算后的钟点。两者非空才认为能入库。
  final String? startTime;
  final String? endTime;

  final String? location;
  final String? note;

  /// 0=每周，1=单周，2=双周。
  final int weekParity;

  /// 非空表示这节没能换算成时间（如作息表里没有该节次），UI 要提示并禁选。
  final String? unresolvedReason;

  final Map<String, dynamic>? raw;

  /// 能不能直接入库：时间齐全、能解析，且没有别的毛病（如时间写反）。
  bool get resolved =>
      unresolvedReason == null &&
      startTime != null &&
      endTime != null &&
      tryParseHm(startTime!) != null &&
      tryParseHm(endTime!) != null;

  /// 显示用的时间/节次摘要。
  String get timeLabel {
    if (startTime != null && endTime != null) {
      return '$startTime–$endTime';
    }
    if (period != null && period!.isNotEmpty) return '第 $period 节';
    return '时间未知';
  }
}

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

  /// 课表解析提示词（V3）。三处必须点明，否则真机会解析错：
  /// 1. 作息表整张给出来，限定它只能用这些节次标签；
  /// 2. 「345」是逐字符拆的节次，不是数字 345 —— 汕大课表就这么写；
  /// 3. 一门课一周上多次要拆成多条，否则第二个上课时间会被丢掉。
  static const String timetableSystemPrompt = '''
你是课表解析助手。用户会粘贴一张课表（可能是纯文本、带制表符的表格，或从教务系统
复制出来的乱格式文字）。把它解析成课程列表，只输出一个 JSON 对象，不要解释、
不要 markdown 代码块。

今天是 {TODAY}（星期{WEEKDAY}）。

本校作息表（只能用这些节次标签，不要自己编）：
{PERIOD_TABLE}

大节与小节的对应：{BIG_SECTION}。

关键记号：
课表里像 "12" 表示第 1~2 节，"345" 表示第 3~5 节，"AB" 表示晚上 A~B 节。
这是把节次逐字符写在一起，不是数字 345。遇到这种写法逐字符拆开，用 "-" 连起来
填进 period（"345" → "3-5"，"12" → "1-2"）。

规则：
1. 一门课一周上多次（如周一 1-2 节、周三 3-4 节），每次单独一条，不要合并。
2. day_of_week 必须是数字 1-7（周一=1，周日=7），不要写「周一」。
3. period 填节次范围，只能用上面作息表里出现过的标签，格式如 "1-2"、"3-5"、"A-C"。
   如果原文直接给了钟点（如 08:00-09:40），就把 time 和 end_time 填上、period 填 null。
4. title 保留课程全称，去掉学分、教师、教室、节次等后缀。
5. location 照抄原文（如 "E302"、"东区教学楼204"），没有则 null。
6. note 放教师姓名、周次说明（如 "1-16周"），没有则 null。
7. week_parity：原文明确写单周填 1、双周填 2，没写填 0。
8. 表头行、"上午/下午/晚上"分组标签、星期列标题都不是课程，不要输出。
9. 拿不准的字段填 null，不要猜。

输出格式：
{"courses":[{"title":"高等数学","day_of_week":1,"period":"1-2","time":null,"end_time":null,"location":"E302","note":"张三","week_parity":0}]}
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

    return _draftsFromPayload(await _post(system, userText));
  }

  /// 课表粘贴导入：一段课表文本 → 一批课程草稿。
  ///
  /// 作息表整张塞进提示词，让 AI 只用本校真有的节次标签；换算成钟点的活
  /// 由 [PeriodTable.resolveSpec] 在本机做，不指望 AI 算时间。
  Future<List<AiCourseDraft>> parseTimetable(
    String userText, {
    required PeriodTable periodTable,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const AiException('请先在「我的」页填写 API key');
    }
    if (periodTable.isEmpty) {
      throw const AiException('作息表是空的，先到「我的 → 作息表」配一节');
    }
    final now = _now();
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final today =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final system = timetableSystemPrompt
        .replaceAll('{TODAY}', today)
        .replaceAll('{WEEKDAY}', weekdays[now.weekday - 1])
        .replaceAll('{PERIOD_TABLE}', _periodTableText(periodTable))
        .replaceAll('{BIG_SECTION}', _bigSectionText());

    return _coursesFromPayload(await _post(system, userText), periodTable);
  }

  /// 作息表转成提示词里的一行一节的清单。
  static String _periodTableText(PeriodTable table) =>
      table.slots.map((slot) => '第 ${slot.label} 节 ${slot.start}–${slot.end}').join('\n');

  static String _bigSectionText() => PeriodTable.bigSectionHint.entries
      .map((entry) => '${entry.key}=${entry.value}节')
      .join('，');

  /// OpenAI 兼容的 Chat Completions 调用，返回模型输出 JSON 解析后的对象。
  Future<Object?> _post(String system, String userText) async {
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
      return jsonDecode(content);
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

  /// 兼容 {"courses":[...]}（约定）、{"items":[...]}、裸数组、单个对象。
  List<AiCourseDraft> _coursesFromPayload(Object? payload, PeriodTable table) {
    final List<Object?> rawItems;
    if (payload is Map<String, dynamic>) {
      final courses = payload['courses'] ?? payload['items'];
      if (courses is List) {
        rawItems = courses;
      } else if (payload.containsKey('title')) {
        rawItems = [payload];
      } else {
        throw const AiException('AI 返回缺少 courses 列表');
      }
    } else if (payload is List) {
      rawItems = payload;
    } else {
      throw const AiException('AI 返回格式无法解析');
    }

    final drafts = <AiCourseDraft>[];
    for (final item in rawItems) {
      if (item is! Map<String, dynamic>) continue;
      final draft = _courseFromJson(item, table);
      if (draft != null) drafts.add(draft);
    }
    if (drafts.isEmpty) {
      throw const AiException('AI 没有解析出任何课程');
    }
    return drafts;
  }

  /// 一门课：节次优先用本机作息表换算，AI 给的钟点只作兜底。
  ///
  /// 为什么不优先用 AI 给的钟点：节次是原文里客观存在的，「第 3-5 节」用
  /// 作息表算出来一定对；AI 自己换算出来的钟点可能凭空多出 5 分钟。
  AiCourseDraft? _courseFromJson(Map<String, dynamic> json, PeriodTable table) {
    final title = (json['title'] as String?)?.trim();
    if (title == null || title.isEmpty) return null;

    final dayOfWeek = parseDayOfWeek(json['day_of_week']);
    // 不知道周几的课程没法落到课表上，直接丢弃而不是猜成周一。
    if (dayOfWeek == null) return null;

    final periodRaw = (json['period'] as String?)?.trim();
    String? start;
    String? end;
    String? reason;

    if (periodRaw != null && periodRaw.isNotEmpty) {
      final span = table.resolveSpec(periodRaw);
      if (span != null) {
        start = span.start;
        end = span.end;
      } else {
        reason = '第 $periodRaw 节不在作息表里';
      }
    }
    start ??= _cleanTime(json['time']);
    end ??= _cleanTime(json['end_time']);

    if (start == null || end == null) {
      reason ??= '原文没给出可用的上课时间';
    } else if (tryParseHm(end)! <= tryParseHm(start)!) {
      reason = '结束时间早于开始时间';
    } else {
      // 换算成功就把中间过程的抱怨清掉（节次认不出但原文有钟点的情况）。
      reason = null;
    }

    final location = (json['location'] as String?)?.trim();
    final note = (json['note'] as String?)?.trim();

    return AiCourseDraft(
      title: title,
      dayOfWeek: dayOfWeek,
      period: (periodRaw == null || periodRaw.isEmpty) ? null : periodRaw,
      startTime: start,
      endTime: end,
      location: (location == null || location.isEmpty) ? null : location,
      note: (note == null || note.isEmpty) ? null : note,
      weekParity: _parseWeekParity(json['week_parity']),
      unresolvedReason: reason,
      raw: json,
    );
  }

  static String? _cleanTime(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return null;
    final minutes = tryParseHm(raw.trim());
    return minutes == null ? null : hm(minutes);
  }

  static int _parseWeekParity(Object? raw) {
    if (raw is num) {
      final value = raw.toInt();
      return (value == 1 || value == 2) ? value : 0;
    }
    if (raw is String) {
      final text = raw.trim();
      if (text.contains('单')) return 1;
      if (text.contains('双')) return 2;
      final value = int.tryParse(text);
      if (value == 1 || value == 2) return value!;
    }
    return 0;
  }
}
