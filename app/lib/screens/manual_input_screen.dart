import 'package:flutter/material.dart';

import '../models/course.dart';
import '../models/event_item.dart';
import '../models/task.dart';
import '../models/timeline.dart';
import '../services/db_service.dart';
import '../services/notification_service.dart';

enum InputType { event, task, course }

class ManualInputScreen extends StatefulWidget {
  const ManualInputScreen({
    super.key,
    required this.db,
    required this.notifications,
  });

  final DbService db;
  final NotificationService notifications;

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

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final iso =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    _date.text = iso;
    _semesterStart.text = iso;
    _semesterEnd.text = dateOnlyString(now.add(const Duration(days: 120)));
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

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _message = '请先填事项');
      return;
    }
    final date = _parseDate(_date.text.trim());
    if (date == null) {
      setState(() => _message = '日期格式应为 yyyy-MM-dd');
      return;
    }

    final dateText = normalizeDateText(_date.text.trim());
    final timeText = normalizeTimeText(_time.text.trim());
    final endTimeText = normalizeTimeText(_endTime.text.trim());
    final semesterStartText = normalizeDateText(_semesterStart.text.trim());
    final semesterEndText = normalizeDateText(_semesterEnd.text.trim());

    try {
      switch (_type) {
        case InputType.event:
          final minutes = _parseHm(timeText);
          if (minutes == null) {
            setState(() => _message = '时间格式应为 HH:mm');
            return;
          }
          final startAt = DateTime(
            date.year,
            date.month,
            date.day,
            minutes ~/ 60,
            minutes % 60,
          );
          final id = await widget.db.insertEvent(
            EventItem(
              title: title,
              startAt: startAt.toIso8601String(),
              location: _location.text.trim().isEmpty
                  ? null
                  : _location.text.trim(),
              note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            ),
          );
          await _safeSchedule(100000 + id, startAt, title);
          break;
        case InputType.task:
          final rawTime = timeText;
          final minutes = rawTime.isEmpty ? null : _parseHm(rawTime);
          if (rawTime.isNotEmpty && minutes == null) {
            setState(() => _message = '时间格式应为 HH:mm，或留空表示全天');
            return;
          }
          final id = await widget.db.insertTask(
            TaskItem(
              title: title,
              dueDate: dateText,
              dueTime: minutes == null ? null : timeText,
              location: _location.text.trim().isEmpty
                  ? null
                  : _location.text.trim(),
              note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            ),
          );
          // 无钟点任务也在当天 09:00 提醒（不是不提醒）。
          final at = resolveTaskReminderAt(date, timeText);
          if (at != null && at.isAfter(DateTime.now())) {
            await _safeSchedule(200000 + id, at, title);
          }
          break;
        case InputType.course:
          final begin = _parseHm(timeText);
          final end = _parseHm(endTimeText);
          if (begin == null || end == null) {
            setState(() => _message = '时间格式应为 HH:mm');
            return;
          }
          await widget.db.insertCourse(
            Course(
              title: title,
              dayOfWeek: _dayOfWeek,
              startTime: timeText,
              endTime: endTimeText,
              location: _location.text.trim().isEmpty
                  ? null
                  : _location.text.trim(),
              semesterStart: semesterStartText,
              semesterEnd: semesterEndText,
              weekParity: _weekParity,
            ),
          );
          break;
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _message = '保存失败：$e');
    }
  }

  Future<void> _safeSchedule(int id, DateTime at, String title) async {
    try {
      await widget.notifications.schedule(
        id: id,
        title: title,
        body: '到点了：$title',
        eventTime: at,
      );
    } catch (e) {
      // 数据已落盘；过期时间的提醒失败不应回滚录入。
      _message = '已保存，但提醒设置失败：$e';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('新建条目')),
      body: SingleChildScrollView(
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
              onSelectionChanged: (value) =>
                  setState(() => _type = value.first),
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
                    DropdownMenuItem(value: i, child: Text('周${_weekName(i)}')),
                ],
                onChanged: (value) => setState(() => _dayOfWeek = value ?? 1),
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
                labelText: _type == InputType.task ? '时间（可留空）' : '开始时间（HH:mm）',
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
