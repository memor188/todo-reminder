// 课表解析提示词的真实性探针（一次性工具，不参与测试与构建）。
//
// 单元测试里的 AI 响应都是构造出来的，只能证明「假设模型返回了正确 JSON，
// 解析逻辑没问题」。提示词本身模型能不能听懂，只有真打一次 API 才知道。
//
// 用法：DEEPSEEK_KEY=sk-xxx dart run tool/timetable_probe.dart
import 'dart:io';

import 'package:todo_app/models/period_table.dart';
import 'package:todo_app/services/ai_service.dart';

const String sample = '''
2026-2027学年秋季学期课表
课程名称        学分  教师   周次     星期  节次  上课地点
高等数学A       5     张三   1-16周   一    12    E302
高等数学A       5     张三   1-16周   三    12    E302
大学物理        4     李四   1-16周   二    345   E401
电路分析基础    3     王五   1-16周   四    34    E105
大学英语        2     赵六   1-16周   五    67    E208
体育            1     周八   1-16周   三    78    田径场
程序设计基础    3     吴九   1-16周   三    AB    E210
''';

Future<void> main() async {
  final key = Platform.environment['DEEPSEEK_KEY'] ?? '';
  if (key.trim().isEmpty) {
    stderr.writeln('缺少 DEEPSEEK_KEY 环境变量');
    exit(1);
  }

  final service = AiService(
    baseUrl: 'https://api.deepseek.com',
    apiKey: key,
    model: 'deepseek-chat',
  );

  stdout.writeln('样例课表 7 行，期望解析出 7 门课\n');
  final drafts = await service.parseTimetable(
    sample,
    periodTable: PeriodTable.shantouDefault,
  );

  stdout.writeln('实际解析出 ${drafts.length} 门：');
  for (final draft in drafts) {
    final flag = draft.resolved ? 'OK' : '需处理';
    stdout.writeln(
      '  [$flag] ${draft.title} | 周${draft.dayOfWeek} | '
      'period=${draft.period ?? "-"} | '
      '${draft.startTime ?? "?"}-${draft.endTime ?? "?"} | '
      '${draft.location ?? "-"} | 单双周=${draft.weekParity}'
      '${draft.unresolvedReason == null ? "" : " | ${draft.unresolvedReason}"}',
    );
  }
  stdout.writeln('\n期望时间：12→08:00-09:40  345→10:00-12:35  34→10:00-11:40 '
      '67→14:00-15:40  78→16:00-17:40  AB→19:20-21:00');
}
