import 'package:flutter/material.dart';

import '../models/course.dart';
import '../models/period_table.dart';
import '../models/semester_plan.dart';
import '../models/timeline.dart';
import '../services/ai_service.dart';
import '../services/db_service.dart';
import '../services/settings_service.dart';
import '../widgets/masked_formatters.dart';

/// 课表粘贴导入（V3）。
///
/// 分工：AI 只把一堆文字拆成「周几 + 第几节」，节次换算成钟点由本机作息表做。
/// 导入前一定过一遍预览，绝不直接把 AI 输出写库——这是全项目一以贯之的规矩。
class TimetableImportScreen extends StatefulWidget {
  const TimetableImportScreen({
    super.key,
    required this.settings,
    required this.db,
  });

  final SettingsService settings;
  final DbService db;

  @override
  State<TimetableImportScreen> createState() => _TimetableImportScreenState();
}

class _ImportRow {
  _ImportRow({required this.draft, required this.selected});

  AiCourseDraft draft;
  bool selected;
}

class _TimetableImportScreenState extends State<TimetableImportScreen> {
  final _input = TextEditingController();
  List<_ImportRow> _rows = const [];
  List<SemesterPlan> _plans = const [];
  SemesterPlan? _plan;
  bool _busy = false;
  bool _importing = false;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    _plans = widget.settings.semesterPlans;
    if (_plans.isNotEmpty) {
      // 默认选当前日期命中的那个学期，跟新建课程的行为保持一致。
      _plan = SemesterPlan.pickForDate(_plans, DateTime.now()) ?? _plans.first;
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  PeriodTable get _table => widget.settings.periodTable;

  Future<void> _parse() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      setState(() {
        _error = '先把课表文字粘进来';
        _message = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final service = AiService(
        baseUrl: widget.settings.baseUrl,
        apiKey: widget.settings.apiKey,
        model: widget.settings.model,
      );
      final drafts = await service.parseTimetable(text, periodTable: _table);
      if (!mounted) return;
      final bad = drafts.where((draft) => !draft.resolved).length;
      setState(() {
        _rows = [
          for (final draft in drafts)
            _ImportRow(draft: draft, selected: draft.resolved),
        ];
        _message = bad == 0
            ? '解析出 ${drafts.length} 门课，核对后导入'
            : '解析出 ${drafts.length} 门课，其中 $bad 门的时间认不出来，需要手动补';
      });
    } on AiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '解析失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 给认不出节次的课手动补时间。
  Future<void> _fixTimes(_ImportRow row) async {
    final result = await showDialog<PeriodSpan>(
      context: context,
      builder: (context) => _TimesDialog(
        title: row.draft.title,
        initialStart: row.draft.startTime,
        initialEnd: row.draft.endTime,
      ),
    );
    if (result == null) return;
    setState(() {
      row.draft = AiCourseDraft(
        title: row.draft.title,
        dayOfWeek: row.draft.dayOfWeek,
        period: row.draft.period,
        startTime: result.start,
        endTime: result.end,
        location: row.draft.location,
        note: row.draft.note,
        weekParity: row.draft.weekParity,
        raw: row.draft.raw,
      );
      row.selected = true;
    });
  }

  Future<void> _import() async {
    final plan = _plan;
    if (plan == null) {
      setState(() => _error = '先去「我的 → 学期方案」建一个，课程要有学期起止');
      return;
    }
    final picked = _rows
        .where((row) => row.selected && row.draft.resolved)
        .toList();
    if (picked.isEmpty) {
      setState(() => _error = '没有勾选可导入的课程');
      return;
    }

    setState(() {
      _importing = true;
      _error = null;
    });
    var inserted = 0;
    var skipped = 0;
    try {
      // 同一门课同一时段已经存在就跳过：重复点两次导入不该把课表刷成两倍。
      final existing = (await widget.db.queryAll()).courses;
      for (final row in picked) {
        final draft = row.draft;
        final duplicated = existing.any(
          (course) =>
              course.title == draft.title &&
              course.dayOfWeek == draft.dayOfWeek &&
              course.startTime == draft.startTime,
        );
        if (duplicated) {
          skipped++;
          continue;
        }
        await widget.db.insertCourse(
          Course(
            title: draft.title,
            dayOfWeek: draft.dayOfWeek,
            startTime: draft.startTime!,
            endTime: draft.endTime!,
            location: draft.location,
            note: draft.note,
            semesterStart: plan.start,
            semesterEnd: plan.end,
            weekParity: draft.weekParity,
          ),
        );
        inserted++;
      }
      if (!mounted) return;
      final skippedText = skipped == 0 ? '' : '，跳过 $skipped 门已存在的';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 $inserted 门课$skippedText')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _importing = false;
          _error = '导入失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('课表导入')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('timetable_input'),
                  controller: _input,
                  maxLines: 6,
                  minLines: 4,
                  decoration: const InputDecoration(
                    labelText: '把课表文字粘在这里',
                    hintText: '从教务系统或课表截图里复制的文字，格式乱也没关系',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _plans.isEmpty
                          ? const Text(
                              '还没有学期方案，导入前先去「我的」建一个',
                              style: TextStyle(color: Colors.grey, fontSize: 12),
                            )
                          : DropdownButtonFormField<String>(
                              key: ValueKey('import_plan_${_plan?.id}'),
                              initialValue: _plan?.id,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: '学期方案',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: [
                                for (final plan in _plans)
                                  DropdownMenuItem(
                                    value: plan.id,
                                    child: Text(
                                      plan.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (id) {
                                if (id == null) return;
                                setState(() {
                                  _plan = _plans.firstWhere(
                                    (plan) => plan.id == id,
                                  );
                                });
                              },
                            ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      key: const Key('timetable_parse'),
                      onPressed: _busy ? null : _parse,
                      child: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('解析'),
                    ),
                  ],
                ),
                if (_message != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _message!,
                      key: const Key('timetable_message'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _error!,
                      key: const Key('timetable_error'),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 24),
          Expanded(
            child: _rows.isEmpty
                ? const Center(
                    child: Text(
                      '粘贴课表后点「解析」，\n解析结果会列在这里供你核对。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: _rows.length,
                    itemBuilder: (context, index) {
                      final row = _rows[index];
                      final draft = row.draft;
                      final place = draft.location == null
                          ? ''
                          : ' · ${draft.location}';
                      return CheckboxListTile(
                        key: Key('import_row_$index'),
                        value: row.selected,
                        onChanged: (value) => setState(
                          () => row.selected = value ?? false,
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(draft.title),
                        subtitle: Text(
                          '周${_weekName(draft.dayOfWeek)} '
                          '${draft.timeLabel}$place',
                          style: TextStyle(
                            fontSize: 12,
                            color: draft.resolved
                                ? null
                                : Theme.of(context).colorScheme.error,
                          ),
                        ),
                        secondary: draft.resolved
                            ? null
                            : TextButton(
                                key: Key('fix_times_$index'),
                                onPressed: () => _fixTimes(row),
                                child: const Text('补时间'),
                              ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('timetable_import'),
                  onPressed: _importing || _rows.isEmpty ? null : _import,
                  child: Text(
                    _importing
                        ? '导入中…'
                        : '导入勾选的 ${_rows.where((row) => row.selected && row.draft.resolved).length} 门课',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _weekName(int day) =>
      const ['一', '二', '三', '四', '五', '六', '日'][day - 1];
}

/// 手动补时间的小弹窗。
class _TimesDialog extends StatefulWidget {
  const _TimesDialog({
    required this.title,
    this.initialStart,
    this.initialEnd,
  });

  final String title;
  final String? initialStart;
  final String? initialEnd;

  @override
  State<_TimesDialog> createState() => _TimesDialogState();
}

class _TimesDialogState extends State<_TimesDialog> {
  late final TextEditingController _start;
  late final TextEditingController _end;
  String? _message;

  @override
  void initState() {
    super.initState();
    _start = TextEditingController(text: widget.initialStart ?? '');
    _end = TextEditingController(text: widget.initialEnd ?? '');
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  void _save() {
    final start = tryParseHm(_start.text.trim());
    final end = tryParseHm(_end.text.trim());
    if (start == null || end == null) {
      setState(() => _message = '时间格式应为 HH:mm');
      return;
    }
    if (end <= start) {
      setState(() => _message = '结束时间要晚于开始时间');
      return;
    }
    Navigator.pop(
      context,
      PeriodSpan(labels: const [], start: hm(start), end: hm(end)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('fix_start'),
            controller: _start,
            keyboardType: TextInputType.number,
            inputFormatters: const [TimeMaskFormatter()],
            decoration: const InputDecoration(
              labelText: '开始',
              hintText: '1000',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('fix_end'),
            controller: _end,
            keyboardType: TextInputType.number,
            inputFormatters: const [TimeMaskFormatter()],
            decoration: const InputDecoration(
              labelText: '结束',
              hintText: '1140',
              border: OutlineInputBorder(),
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _message!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          key: const Key('fix_save'),
          onPressed: _save,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
