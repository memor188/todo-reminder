import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/course.dart';
import '../models/period_table.dart';
import '../models/semester_plan.dart';
import '../models/timeline.dart';
import '../services/ai_service.dart';
import '../services/db_service.dart';
import '../services/settings_service.dart';
import '../services/timetable_file_parser.dart';
import '../services/xls_reader.dart';
import '../widgets/masked_formatters.dart';

/// 用户选中的课表文件：图片、`.xls`、或纯文本表格。
///
/// 抽成值对象是为了让 widget 测试能塞假文件进来——`FilePicker` 走平台通道，
/// 测试环境里调不动。真机上由 `_pickWithFilePicker` 填这个对象。
class PickedTimetableFile {
  const PickedTimetableFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// 课表导入（V3 粘贴文字 / V4 图片与文件）。
///
/// 三条入口，产出同一种 [AiCourseDraft]，后面的预览与入库完全共用：
/// - 粘贴文字 → AI 拆结构；
/// - 截图/照片 → AI 识图（要 `deepseek-flash` 这类多模态模型）；
/// - 教务系统导出的 `.xls` → 本机直接解析，不联网、不花钱、比模型猜得准。
///
/// 导入前一定过一遍预览，绝不直接把解析结果写库——这是全项目一以贯之的规矩。
class TimetableImportScreen extends StatefulWidget {
  const TimetableImportScreen({
    super.key,
    required this.settings,
    required this.db,
    this.pickFile,
    this.aiFactory,
  });

  final SettingsService settings;
  final DbService db;

  /// 测试注入点：不给就用系统文件选择器。
  final Future<PickedTimetableFile?> Function()? pickFile;

  /// 测试注入点：不给就按「我的」页里的配置造一个真的 [AiService]。
  final AiService Function()? aiFactory;

  @override
  State<TimetableImportScreen> createState() => _TimetableImportScreenState();
}

class _ImportRow {
  _ImportRow({required this.draft, required this.selected});

  AiCourseDraft draft;
  bool selected;
}

class _TimetableImportScreenState extends State<TimetableImportScreen> {
  /// 选文件时放开这些后缀。`.xlsx` 故意留着——好给一句「另存为 .xls」的提示，
  /// 让选择器直接把它藏了，用户只会以为 App 坏了。
  static const List<String> pickableExtensions = [
    'xls',
    'xlsx',
    'csv',
    'tsv',
    'txt',
    'md',
    'html',
    'htm',
    'png',
    'jpg',
    'jpeg',
    'webp',
  ];

  final _input = TextEditingController();
  List<_ImportRow> _rows = const [];
  List<SemesterPlan> _plans = const [];
  SemesterPlan? _plan;
  bool _busy = false;
  bool _importing = false;
  String? _message;
  String? _error;

  /// 上次读进来的文件名，显示在提示里，让人知道这批课是从哪儿来的。
  String? _sourceName;

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

  AiService _service() =>
      widget.aiFactory?.call() ??
      AiService(
        baseUrl: widget.settings.baseUrl,
        apiKey: widget.settings.apiKey,
        model: widget.settings.model,
      );

  // ---------------------------------------------------------------- 文字粘贴

  Future<void> _parse() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      setState(() {
        _error = '先把课表文字粘进来，或者用「选文件 / 截图」';
        _message = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
      _sourceName = null;
    });
    try {
      final drafts = await _service().parseTimetable(text, periodTable: _table);
      if (!mounted) return;
      _applyDrafts(drafts);
    } on AiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '解析失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ 文件 / 图片

  Future<void> _pickAndParse() async {
    setState(() {
      _error = null;
      _message = null;
    });
    PickedTimetableFile? picked;
    try {
      picked = await (widget.pickFile ?? _pickWithFilePicker)();
    } catch (e) {
      if (mounted) setState(() => _error = '打开文件选择器失败：$e');
      return;
    }
    if (picked == null || !mounted) return;
    await _parseFile(picked);
  }

  /// 系统文件选择器。
  ///
  /// file_picker 13 起 `pickFile` 直接返回 `PlatformFile`，字节用
  /// `readAsBytes()` 现读——老版本那个「withData + bytes 字段」已经没有了。
  /// 课表文件才几十 KB，整份读进内存没压力。
  static Future<PickedTimetableFile?> _pickWithFilePicker() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: pickableExtensions,
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return PickedTimetableFile(name: file.name, bytes: bytes);
  }

  Future<void> _parseFile(PickedTimetableFile file) async {
    final lower = file.name.toLowerCase();
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
      _sourceName = file.name;
    });
    try {
      if (lower.endsWith('.xlsx')) {
        setState(
          () => _error =
              '这是新版 .xlsx，本机只认老版 .xls。'
              '在 Excel / WPS 里「另存为 → Excel 97-2003 工作簿(*.xls)」再导一次，'
              '或者直接从教务系统导出 .xls / CSV。',
        );
        return;
      }
      if (lower.endsWith('.xls')) {
        _parseXls(file);
      } else if (_isImage(lower)) {
        await _parseImage(file, lower);
      } else if (isTextTimetable(lower)) {
        await _parseTextFile(file);
      } else {
        setState(() => _error = '不认识的文件类型：${file.name}');
      }
    } on XlsFormatException catch (e) {
      if (mounted) setState(() => _error = '.xls 读不出来：${e.message}');
    } on AiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '读文件失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// `.xls` 走本地解析：不联网、不花钱，也不会把课表内容发给模型。
  void _parseXls(PickedTimetableFile file) {
    if (_table.isEmpty) {
      setState(() => _error = '作息表是空的，节次换算不了。先去「我的 → 作息表」配一节');
      return;
    }
    final sheet = readFirstXlsSheet(file.bytes);
    final drafts = coursesFromXlsSheet(sheet, _table);
    if (drafts.isEmpty) {
      setState(
        () => _error =
            '这个 .xls 里没找到课程格子。可能是「学生个人课表」以外的表，'
            '或者节次列不是「一(01,02)」这种写法——那就把内容复制出来粘贴解析。',
      );
      return;
    }
    _applyDrafts(drafts, localNote: '本机直接读的，没联网');
  }

  Future<void> _parseImage(PickedTimetableFile file, String lower) async {
    final blocked = _visionBlockedReason();
    if (blocked != null) {
      setState(() => _error = blocked);
      return;
    }
    final drafts = await _service().parseTimetable(
      '这是课表截图，请解析成课程列表。',
      periodTable: _table,
      imageBytes: file.bytes,
      imageMime: _mimeOf(lower),
    );
    if (!mounted) return;
    _applyDrafts(drafts);
  }

  Future<void> _parseTextFile(PickedTimetableFile file) async {
    final text = textFromFile(file.bytes);
    if (text.trim().isEmpty) {
      setState(() => _error = '${file.name} 是空的，或者编码认不出来');
      return;
    }
    // 顺手填进输入框：既让用户看得见读了什么，也能在解析偏了时直接手改再解析。
    _input.text = text;
    final drafts = await _service().parseTimetable(text, periodTable: _table);
    if (!mounted) return;
    _applyDrafts(drafts);
  }

  /// 官方域名下只有多模态模型能读图。别家供应商不好判断，放行让他试。
  String? _visionBlockedReason() {
    final settings = widget.settings;
    if (!settings.baseUrl.contains('deepseek.com')) return null;
    if (settings.model.toLowerCase().contains('flash')) return null;
    return '当前模型 ${settings.model} 不能识图。去「我的」把模型换成 deepseek-flash，'
        '或者改用「选文件」导 .xls、粘贴文字。';
  }

  static bool _isImage(String lower) => const [
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
  ].any(lower.endsWith);

  static String _mimeOf(String lower) {
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  /// 解析结果统一落地：勾选状态、提示语、错误清理都在这儿，避免三条入口各写一遍。
  void _applyDrafts(List<AiCourseDraft> drafts, {String? localNote}) {
    final bad = drafts.where((draft) => !draft.resolved).length;
    final head = localNote == null
        ? '解析出 ${drafts.length} 门课'
        : '从 $_sourceName 读出 ${drafts.length} 门课（$localNote）';
    setState(() {
      _rows = [
        for (final draft in drafts)
          _ImportRow(draft: draft, selected: draft.resolved),
      ];
      _error = null;
      _message = bad == 0
          ? '$head，核对后导入'
          : '$head，其中 $bad 门的时间认不出来，需要手动补';
    });
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
        teacher: row.draft.teacher,
        weeks: row.draft.weeks,
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
      // 同一门课同一时段、同一批周次已经存在就跳过：重复点两次导入不该把课表刷成两倍。
      // 周次要一起比，否则「线性代数 3-12 周」和「13-14 周」会被当成同一门吞掉一条。
      final existing = (await widget.db.queryAll()).courses;
      for (final row in picked) {
        final draft = row.draft;
        final duplicated = existing.any(
          (course) =>
              course.title == draft.title &&
              course.dayOfWeek == draft.dayOfWeek &&
              course.startTime == draft.startTime &&
              (course.weeks ?? '') == (draft.weeks ?? ''),
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
            teacher: draft.teacher,
            weeks: draft.weeks,
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
                  maxLines: 5,
                  minLines: 3,
                  decoration: const InputDecoration(
                    labelText: '把课表文字粘在这里',
                    hintText: '也可以直接点下面的「选文件 / 截图」',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('timetable_pick_file'),
                        onPressed: _busy ? null : _pickAndParse,
                        icon: const Icon(Icons.upload_file, size: 18),
                        label: const Text(
                          '选文件 / 截图',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('timetable_parse'),
                      onPressed: _busy ? null : _parse,
                      child: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('解析文字'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '支持 .xls（教务系统导出，本机解析）、CSV/TXT、以及课表截图',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
                const SizedBox(height: 8),
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
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        '粘贴课表文字，或者丢一个课表文件 / 截图进来，\n'
                        '解析结果会列在这里供你核对。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _rows.length,
                    itemBuilder: (context, index) {
                      final row = _rows[index];
                      final draft = row.draft;
                      return CheckboxListTile(
                        key: Key('import_row_$index'),
                        value: row.selected,
                        onChanged: (value) => setState(
                          () => row.selected = value ?? false,
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(draft.title),
                        subtitle: Text(
                          _subtitle(draft),
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
                        : '导入勾选的 '
                              '${_rows.where((row) => row.selected && row.draft.resolved).length} '
                              '门课',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「周三 10:00–12:35 · E302 · 陈哲 · 3-18周」——教师和周次跟着时间走，一眼能核。
  static String _subtitle(AiCourseDraft draft) {
    final bits = <String>[
      '周${_weekName(draft.dayOfWeek)} ${draft.timeLabel}',
    ];
    if (draft.location != null) bits.add(draft.location!);
    if (draft.teacher != null) bits.add(draft.teacher!);
    if (draft.weeks != null) bits.add('${draft.weeks}周');
    return bits.join(' · ');
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
