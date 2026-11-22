import 'package:flutter/material.dart';

import '../models/course.dart';
import '../models/event_item.dart';
import '../models/semester_plan.dart';
import '../models/task.dart';
import '../models/timeline.dart';
import '../services/db_service.dart';
import '../services/notification_service.dart';
import '../services/reminder_service.dart';
import '../services/settings_service.dart';
import '../widgets/masked_formatters.dart';

enum InputType { event, task, course }

/// 新建 / 编辑条目。
///
/// 2026-11-21 用户要求：日程和课表里的条目点进去要能直接管理（改、删）。
/// 编辑模式传入 [editing]，类型锁定不可切换（跨表迁移不在本期范围）。
class ManualInputScreen extends StatefulWidget {
  const ManualInputScreen({
    super.key,
    required this.db,
    required this.notifications,
    required this.settings,
    this.editing,
  });

  final DbService db;
  final NotificationService notifications;
  final SettingsService settings;

  /// 非空 = 编辑已有条目。
  final TimelineEntry? editing;

  @override
  State<ManualInputScreen> createState() => _ManualInputScreenState();
}

class _ManualInputScreenState extends State<ManualInputScreen> {
  InputType _type = InputType.event;
  final _title = TextEditingController();
  final _date = TextEditingController();
  final _time = TextEditingController(text: '09:00');
  final _endTime = TextEditingController(text: '10:30');
  final _location = TextEditingController();
  final _note = TextEditingController();
  final _semesterStart = TextEditingController();
  final _semesterEnd = TextEditingController();
  int _dayOfWeek = 1;
  int _weekParity = 0;
  String? _message;

  /// 提前多少分钟提醒（V3）。事件默认提前 15 分钟，任务默认到点。
  int _leadMinutes = defaultEventLeadMinutes;

  /// 学期方案：新建课程时一键套用起止日期，省得每门课重打一遍。
  List<SemesterPlan> _plans = const [];
  String? _selectedPlanId;

  /// 编辑目标的 id（各表的自增 id）。
  int? _editingId;
  bool _loadingEdit = false;

  bool get _isEditing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    _plans = widget.settings.semesterPlans;
    final now = DateTime.now();
    final iso = dateOnlyString(now);
    _date.text = iso;
    _semesterStart.text = iso;
    _semesterEnd.text = dateOnlyString(now.add(const Duration(days: 120)));
    if (_isEditing) {
      _loadingEdit = true;
      _loadEditing();
    }
  }

  /// 切到「课程」时按当前日期自动预选命中方案（用户拍板的行为）。
  ///
  /// 只在这一刻做一次：用户之后手动改了学期日期，再切回来不会被他没看见的
  /// 自动逻辑覆盖掉。
  void _autoSelectPlan() {
    if (_plans.isEmpty || _selectedPlanId != null) return;
    final picked = SemesterPlan.pickForDate(_plans, DateTime.now());
    if (picked == null) return;
    _semesterStart.text = picked.start;
    _semesterEnd.text = picked.end;
    setState(() => _selectedPlanId = picked.id);
  }

  void _applyPlan(SemesterPlan plan) {
    setState(() {
      _selectedPlanId = plan.id;
      _semesterStart.text = plan.start;
      _semesterEnd.text = plan.end;
    });
  }

  Future<void> _loadEditing() async {
    final entry = widget.editing!;
    _editingId = entry.sourceId;
    switch (entry.type) {
      case EntryType.event:
        _type = InputType.event;
        final item = await widget.db.findEvent(entry.sourceId);
        if (item != null) {
          _title.text = item.title;
          final start = DateTime.parse(item.startAt);
          _date.text = dateOnlyString(start);
          _time.text = hm(start.hour * 60 + start.minute);
          _location.text = item.location ?? '';
          _note.text = item.note ?? '';
          _leadMinutes = item.remindBeforeMinutes;
        }
        break;
      case EntryType.task:
        _type = InputType.task;
        final item = await widget.db.findTask(entry.sourceId);
        if (item != null) {
          _title.text = item.title;
          _date.text = item.dueDate;
          _time.text = item.dueTime ?? '';
          _location.text = item.location ?? '';
          _note.text = item.note ?? '';
          _leadMinutes = item.remindBeforeMinutes;
        }
        break;
      case EntryType.course:
        _type = InputType.course;
        final item = await widget.db.findCourse(entry.sourceId);
        if (item != null) {
          _title.text = item.title;
          _dayOfWeek = item.dayOfWeek;
          _time.text = item.startTime;
          _endTime.text = item.endTime;
          _semesterStart.text = item.semesterStart;
          _semesterEnd.text = item.semesterEnd;
          _weekParity = item.weekParity;
          _location.text = item.location ?? '';
          _note.text = item.note ?? '';
          // 学期起止正好等于某个方案时选中它，让用户看清这门课挂在哪学期。
          for (final plan in _plans) {
            if (plan.start == item.semesterStart &&
                plan.end == item.semesterEnd) {
              _selectedPlanId = plan.id;
              break;
            }
          }
        }
        break;
    }
    if (!mounted) return;
    setState(() => _loadingEdit = false);
  }

  @override
  void dispose() {
    _title.dispose();
    _date.dispose();
    _time.dispose();
    _endTime.dispose();
    _location.dispose();
    _note.dispose();
    _semesterStart.dispose();
    _semesterEnd.dispose();
    super.dispose();
  }

  static String dateOnlyString(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  DateTime? _parseDate(String value) =>
      DateTime.tryParse(normalizeDateText(value));

  int? _parseHm(String value) {
    final minutes = tryParseHm(value);
    if (minutes == null) return null;
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h < 0 || h > 23 || m < 0 || m > 59) return null;
    return minutes;
  }

  /// 提醒 id 规则必须与编辑/删除时一致，否则旧提醒取消不掉。
  /// 通知 id 的号段规则统一放在 [ReminderService]，这里只做转调，
  /// 免得两个地方各算一套、号段撞了就互相覆盖。
  int _eventScheduleId(int id) => ReminderService.eventNotificationId(id);
  int _taskScheduleId(int id) => ReminderService.taskNotificationId(id);

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _message = '请先填事项');
      return;
    }
    final date = _parseDate(_date.text.trim());
    if (_type != InputType.course && date == null) {
      setState(() => _message = '日期格式应为 yyyy-MM-dd');
      return;
    }

    final dateText = normalizeDateText(_date.text.trim());
    final timeText = normalizeTimeText(_time.text.trim());
    final endTimeText = normalizeTimeText(_endTime.text.trim());
    final semesterStartText = normalizeDateText(_semesterStart.text.trim());
    final semesterEndText = normalizeDateText(_semesterEnd.text.trim());
    final location = _location.text.trim().isEmpty
        ? null
        : _location.text.trim();
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();

    try {
      switch (_type) {
        case InputType.event:
          final minutes = _parseHm(timeText);
          if (minutes == null) {
            setState(() => _message = '时间格式应为 HH:mm');
            return;
          }
          final startAt = DateTime(
            date!.year,
            date.month,
            date.day,
            minutes ~/ 60,
            minutes % 60,
          );
          final item = EventItem(
            id: _editingId,
            title: title,
            startAt: startAt.toIso8601String(),
            location: location,
            note: note,
            remindBeforeMinutes: _leadMinutes,
          );
          final int id;
          if (_editingId != null) {
            await widget.db.updateEvent(item);
            id = _editingId!;
          } else {
            id = await widget.db.insertEvent(item);
          }
          // 事件已过时 resolveRemindAt 返回 null，用 startAt 兜底：它也在过去，
          // _reschedule 会先取消旧提醒再跳过重排。
          await _reschedule(
            id: _eventScheduleId(id),
            at:
                resolveRemindAt(
                  eventTime: startAt,
                  leadMinutes: _leadMinutes,
                  now: DateTime.now(),
                ) ??
                startAt,
            eventTime: startAt,
            title: title,
            wasEditing: _isEditing,
          );
          break;
        case InputType.task:
          final rawTime = timeText;
          final minutes = rawTime.isEmpty ? null : _parseHm(rawTime);
          if (rawTime.isNotEmpty && minutes == null) {
            setState(() => _message = '时间格式应为 HH:mm，或留空表示全天');
            return;
          }
          final item = TaskItem(
            id: _editingId,
            title: title,
            dueDate: dateText,
            dueTime: minutes == null ? null : timeText,
            location: location,
            note: note,
            remindBeforeMinutes: _leadMinutes,
          );
          final int id;
          if (_editingId != null) {
            await widget.db.updateTask(item);
            id = _editingId!;
          } else {
            id = await widget.db.insertTask(item);
          }
          // 无钟点任务也在当天 09:00 提醒（不是不提醒），再按提前量前移。
          final dueAt = resolveTaskReminderAt(date!, timeText);
          final at = dueAt == null
              ? null
              : resolveRemindAt(
                  eventTime: dueAt,
                  leadMinutes: _leadMinutes,
                  now: DateTime.now(),
                );
          if (at != null) {
            await _reschedule(
              id: _taskScheduleId(id),
              at: at,
              eventTime: dueAt!,
              title: title,
              wasEditing: _isEditing,
            );
          } else if (_isEditing) {
            // 改了时间又变成排不上，旧提醒必须撤掉，否则会按旧时间响。
            await widget.notifications.cancel(_taskScheduleId(id));
          }
          break;
        case InputType.course:
          final begin = _parseHm(timeText);
          final end = _parseHm(endTimeText);
          if (begin == null || end == null) {
            setState(() => _message = '时间格式应为 HH:mm');
            return;
          }
          final item = Course(
            id: _editingId,
            title: title,
            dayOfWeek: _dayOfWeek,
            startTime: timeText,
            endTime: endTimeText,
            location: location,
            semesterStart: semesterStartText,
            semesterEnd: semesterEndText,
            weekParity: _weekParity,
          );
          final int id;
          if (_editingId != null) {
            await widget.db.updateCourse(item);
            id = _editingId!;
          } else {
            id = await widget.db.insertCourse(item);
          }
          // 课程以前只入库不排提醒，导完课表到点手机不响。现在按未来
          // 8 周的每个课时排一次性闹钟（单双周、学期边界都算进去）。
          await _syncCourse(id);
          break;
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _message = '保存失败：$e');
    }
  }

  /// 编辑时先取消旧提醒再重排，避免改了时间旧闹钟还留着。
  Future<void> _reschedule({
    required int id,
    required DateTime at,
    required DateTime eventTime,
    required String title,
    required bool wasEditing,
  }) async {
    try {
      if (wasEditing) await widget.notifications.cancel(id);
    } catch (_) {
      // 旧提醒可能本来就排不上，忽略。
    }
    if (!at.isAfter(DateTime.now())) return;
    try {
      await widget.notifications.schedule(
        id: id,
        title: title,
        // 用实际剩余时间算正文，不是用配置的提前量：退化成立刻提醒时
        // 两者不相等，写配置值会高报。
        body: reminderBody(title, actualLeadMinutes(eventTime, at)),
        eventTime: at,
      );
    } catch (e) {
      // 数据已落盘；提醒失败不应回滚录入。
      _message = '已保存，但提醒设置失败：$e';
    }
  }

  Future<void> _delete() async {
    final id = _editingId;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条？'),
        content: Text(
          _type == InputType.course ? '课程是周期规则，删除后所有周的这节课都会消失。' : '删除后不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm_delete'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      switch (_type) {
        case InputType.event:
          // 取消失败不能挡住删除——用户要的是数据没了。
          await _safeCancel(_eventScheduleId(id));
          await widget.db.deleteEvent(id);
          break;
        case InputType.task:
          await _safeCancel(_taskScheduleId(id));
          await widget.db.deleteTask(id);
          break;
        case InputType.course:
          // 先撤闹钟再删数据：删完就查不到这门课排过几条了。
          await ReminderService(widget.notifications).cancelCourse(id);
          await widget.db.deleteCourse(id);
          break;
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _message = '删除失败：$e');
    }
  }

  /// 保存课程后立刻排这门课的提醒（新建和改名改时间都走这里，
  /// 重排会顺手把多出来的旧槽位撤掉）。
  Future<void> _syncCourse(int id) async {
    try {
      final course = await widget.db.findCourse(id);
      if (course == null) return;
      await ReminderService(widget.notifications).syncCourse(course);
    } catch (e) {
      // 数据已落盘；提醒失败不应回滚录入。
      _message = '已保存，但课程提醒设置失败：$e';
    }
  }

  Future<void> _safeCancel(int id) async {
    try {
      await widget.notifications.cancel(id);
    } catch (_) {
      // 没有这条提醒也算正常。
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? '编辑条目' : '新建条目')),
      body: _loadingEdit
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SegmentedButton<InputType>(
                    segments: const [
                      ButtonSegment(value: InputType.event, label: Text('事件')),
                      ButtonSegment(value: InputType.task, label: Text('任务')),
                      ButtonSegment(value: InputType.course, label: Text('课程')),
                    ],
                    selected: {_type},
                    // 编辑时锁类型：跨表迁移不在本期范围。
                    onSelectionChanged: _isEditing
                        ? null
                        : (value) {
                            setState(() {
                              _type = value.first;
                              // 切类型时回到该类型的默认提前量，避免把事件的
                              // 15 分钟带到任务上（任务到点即可）。
                              _leadMinutes = value.first == InputType.task
                                  ? defaultTaskLeadMinutes
                                  : defaultEventLeadMinutes;
                            });
                            if (value.first == InputType.course) {
                              _autoSelectPlan();
                            }
                          },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('input_title'),
                    controller: _title,
                    decoration: const InputDecoration(
                      labelText: '事项',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_type == InputType.course)
                    DropdownButtonFormField<int>(
                      initialValue: _dayOfWeek,
                      decoration: const InputDecoration(labelText: '星期'),
                      items: [
                        for (var i = 1; i <= 7; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text('周${_weekName(i)}'),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => _dayOfWeek = value ?? 1),
                    )
                  else
                    TextField(
                      key: const Key('input_date'),
                      controller: _date,
                      keyboardType: TextInputType.number,
                      inputFormatters: const [DateMaskFormatter()],
                      decoration: const InputDecoration(
                        labelText: '日期',
                        hintText: '20261121',
                        helperText: '只敲数字，横杠自动补',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('input_time'),
                    controller: _time,
                    keyboardType: TextInputType.number,
                    inputFormatters: const [TimeMaskFormatter()],
                    decoration: InputDecoration(
                      labelText: _type == InputType.task ? '时间（可留空）' : '开始时间',
                      hintText: '0900',
                      helperText: '只敲数字，冒号自动补',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (_type != InputType.course) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      // initialValue 只在构建时生效，靠 key 随值重建同步显示。
                      key: ValueKey('input_lead_$_leadMinutes'),
                      initialValue: _leadMinutes,
                      decoration: const InputDecoration(
                        labelText: '提前提醒',
                        helperText: '事件默认提前 15 分钟，任务默认到点',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final minutes in leadMinuteOptions)
                          DropdownMenuItem(
                            value: minutes,
                            child: Text(leadLabel(minutes)),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => _leadMinutes = value ?? 0),
                    ),
                  ],
                  if (_type == InputType.course) ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('input_end_time'),
                      controller: _endTime,
                      keyboardType: TextInputType.number,
                      inputFormatters: const [TimeMaskFormatter()],
                      decoration: const InputDecoration(
                        labelText: '结束时间',
                        hintText: '1040',
                        helperText: '只敲数字，冒号自动补',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_plans.isEmpty)
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '还没有学期方案。去「我的」页建一个，以后新建课程就能一键套用。',
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      )
                    else
                      DropdownButtonFormField<String>(
                        // initialValue 只在构建时生效，换方案后靠 key 重建同步显示。
                        key: ValueKey('input_plan_$_selectedPlanId'),
                        initialValue: _selectedPlanId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '学期方案',
                          border: OutlineInputBorder(),
                        ),
                        hint: const Text('未使用方案'),
                        items: [
                          for (final plan in _plans)
                            DropdownMenuItem(
                              value: plan.id,
                              child: Text(
                                '${plan.name}（${plan.start} ~ ${plan.end}）',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (id) {
                          if (id == null) return;
                          _applyPlan(
                            _plans.firstWhere((plan) => plan.id == id),
                          );
                        },
                      ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('input_semester_start'),
                      controller: _semesterStart,
                      keyboardType: TextInputType.number,
                      inputFormatters: const [DateMaskFormatter()],
                      decoration: const InputDecoration(
                        labelText: '学期开始',
                        hintText: '20260901',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('input_semester_end'),
                      controller: _semesterEnd,
                      keyboardType: TextInputType.number,
                      inputFormatters: const [DateMaskFormatter()],
                      decoration: const InputDecoration(
                        labelText: '学期结束',
                        hintText: '20270115',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<int>(
                      key: const Key('input_week_parity'),
                      segments: const [
                        ButtonSegment(value: 0, label: Text('每周')),
                        ButtonSegment(value: 1, label: Text('单周')),
                        ButtonSegment(value: 2, label: Text('双周')),
                      ],
                      selected: {_weekParity},
                      onSelectionChanged: (value) =>
                          setState(() => _weekParity = value.first),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _location,
                    decoration: const InputDecoration(
                      labelText: '地点',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _note,
                    decoration: const InputDecoration(
                      labelText: '备注',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const Key('save_entry'),
                    onPressed: _save,
                    child: const Text('保存'),
                  ),
                  if (_isEditing) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      key: const Key('delete_entry'),
                      onPressed: _delete,
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      label: const Text(
                        '删除这条',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Text(_message!, key: const Key('input_message')),
                  ],
                ],
              ),
            ),
    );
  }

  String _weekName(int day) => ['一', '二', '三', '四', '五', '六', '日'][day - 1];
}
