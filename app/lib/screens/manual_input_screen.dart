import 'package:flutter/material.dart';

import '../models/course.dart';
import '../models/event_item.dart';
import '../models/task.dart';
import '../models/timeline.dart';
import '../services/db_service.dart';
import '../services/notification_service.dart';

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
    this.editing,
  });

  final DbService db;
  final NotificationService notifications;

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

  /// 编辑目标的 id（各表的自增 id）。
  int? _editingId;
  bool _loadingEdit = false;

  bool get _isEditing => widget.editing != null;

  @override
  void initState() {
    super.initState();
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
  int _eventScheduleId(int id) => 100000 + id;
  int _taskScheduleId(int id) => 200000 + id;

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
          );
          final int id;
          if (_editingId != null) {
            await widget.db.updateEvent(item);
            id = _editingId!;
          } else {
            id = await widget.db.insertEvent(item);
          }
          await _reschedule(
            id: _eventScheduleId(id),
            at: startAt,
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
          );
          final int id;
          if (_editingId != null) {
            await widget.db.updateTask(item);
            id = _editingId!;
          } else {
            id = await widget.db.insertTask(item);
          }
          // 无钟点任务也在当天 09:00 提醒（不是不提醒）。
          final at = resolveTaskReminderAt(date!, timeText);
          if (at != null) {
            await _reschedule(
              id: _taskScheduleId(id),
              at: at,
              title: title,
              wasEditing: _isEditing,
            );
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
          if (_editingId != null) {
            await widget.db.updateCourse(item);
          } else {
            await widget.db.insertCourse(item);
          }
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
        body: '到点了：$title',
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
          await widget.db.deleteCourse(id);
          break;
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _message = '删除失败：$e');
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
                        : (value) => setState(() => _type = value.first),
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
                      decoration: const InputDecoration(
                        labelText: '日期（yyyy-MM-dd）',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('input_time'),
                    controller: _time,
                    decoration: InputDecoration(
                      labelText: _type == InputType.task
                          ? '时间（可留空）'
                          : '开始时间（HH:mm）',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (_type == InputType.course) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _endTime,
                      decoration: const InputDecoration(
                        labelText: '结束时间（HH:mm）',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _semesterStart,
                      decoration: const InputDecoration(
                        labelText: '学期开始（yyyy-MM-dd）',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _semesterEnd,
                      decoration: const InputDecoration(
                        labelText: '学期结束（yyyy-MM-dd）',
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
