import 'package:flutter/material.dart';

import '../models/course.dart';
import '../models/event_item.dart';
import '../models/task.dart';
import '../models/timeline.dart';
import '../services/ai_service.dart';
import '../services/db_service.dart';
import '../services/notification_service.dart';
import '../services/settings_service.dart';

/// AI 对话录入：一句话可解析出多条草稿，每条独立确认入库。
///
/// 草稿只活在内存里，用户按下「确认入库」才写表——这是需求里的硬约束：
/// AI 不许直接写数据。
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({
    super.key,
    required this.settings,
    required this.db,
    required this.notifications,
  });

  final SettingsService settings;
  final DbService db;
  final NotificationService notifications;

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

/// 一张草稿卡自己的状态（控制器独立，互不干扰）。
class DraftCard {
  DraftCard(this.draft)
    : type = draft.type,
      dayOfWeek = draft.dayOfWeek ?? DateTime.now().weekday,
      weekParity = 0 {
    title.text = draft.title;
    date.text = draft.date ?? '';
    time.text = draft.time ?? '';
    endTime.text = draft.endTime ?? '';
    location.text = draft.location ?? '';
    note.text = draft.note ?? '';
  }

  final AiDraft draft;
  final title = TextEditingController();
  final date = TextEditingController();
  final time = TextEditingController();
  final endTime = TextEditingController();
  final location = TextEditingController();
  final note = TextEditingController();
  DraftType type;
  int dayOfWeek;
  int weekParity;

  void dispose() {
    title.dispose();
    date.dispose();
    time.dispose();
    endTime.dispose();
    location.dispose();
    note.dispose();
  }
}

class _AiChatScreenState extends State<AiChatScreen> {
  final _input = TextEditingController();
  final _messages = <String>[];
  final _drafts = <DraftCard>[];
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    for (final card in _drafts) {
      card.dispose();
    }
    super.dispose();
  }

  void _say(String text) {
    setState(() => _messages.add(text));
  }

  Future<void> _parse() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _say('我：$text');
    _input.clear();
    setState(() => _busy = true);
    try {
      final service = AiService(
        baseUrl: widget.settings.baseUrl,
        apiKey: widget.settings.apiKey,
        model: widget.settings.model,
      );
      final drafts = await service.parse(text);
      if (!mounted) return;
      setState(() {
        _drafts.addAll(drafts.map(DraftCard.new));
        _messages.add('AI：解析出 ${drafts.length} 条草稿，请核对后逐条确认。');
      });
    } catch (e) {
      _say('AI：解析失败 — $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scheduleIfNeeded(int id, DateTime at, String title) async {
    if (!at.isAfter(DateTime.now())) return;
    try {
      await widget.notifications.schedule(
        id: id,
        title: title,
        body: '到点了：$title',
        eventTime: at,
      );
    } catch (_) {
      // 数据已落盘；提醒失败不回滚录入。
    }
  }

  Future<void> _confirmOne(DraftCard card) async {
    final title = card.title.text.trim();
    if (title.isEmpty) {
      _say('草稿：事项不能为空');
      return;
    }
    final dateText = normalizeDateText(card.date.text.trim());
    final timeText = normalizeTimeText(card.time.text.trim());
    final date = DateTime.tryParse(dateText);
    final minutes = timeText.isEmpty ? null : tryParseHm(timeText);

    try {
      switch (card.type) {
        case DraftType.event:
          if (date == null || minutes == null) {
            _say('草稿：事件需要完整的日期和时间');
            return;
          }
          final at = DateTime(
            date.year,
            date.month,
            date.day,
            minutes ~/ 60,
            minutes % 60,
          );
          final id = await widget.db.insertEvent(
            EventItem(
              title: title,
              startAt: at.toIso8601String(),
              location: card.location.text.trim().isEmpty
                  ? null
                  : card.location.text.trim(),
              note: card.note.text.trim().isEmpty
                  ? null
                  : card.note.text.trim(),
            ),
          );
          await _scheduleIfNeeded(100000 + id, at, title);
          break;
        case DraftType.task:
          if (date == null) {
            _say('草稿：任务需要日期');
            return;
          }
          final id = await widget.db.insertTask(
            TaskItem(
              title: title,
              dueDate: dateText,
              dueTime: minutes == null ? null : timeText,
              location: card.location.text.trim().isEmpty
                  ? null
                  : card.location.text.trim(),
              note: card.note.text.trim().isEmpty
                  ? null
                  : card.note.text.trim(),
            ),
          );
          // 无钟点任务也提醒：当天 09:00（2026-11-21 定稿）。
          final at = resolveTaskReminderAt(date, timeText);
          if (at != null) await _scheduleIfNeeded(200000 + id, at, title);
          break;
        case DraftType.course:
          final today = DateTime.now();
          final start = dateText.isEmpty ? dateKey(today) : dateText;
          final semesterEnd = dateKey(
            DateTime.parse(start).add(const Duration(days: 120)),
          );
          await widget.db.insertCourse(
            Course(
              title: title,
              dayOfWeek: card.dayOfWeek,
              startTime: timeText.isEmpty ? '08:00' : timeText,
              endTime: card.endTime.text.trim().isEmpty
                  ? '09:40'
                  : normalizeTimeText(card.endTime.text.trim()),
              location: card.location.text.trim().isEmpty
                  ? null
                  : card.location.text.trim(),
              semesterStart: start,
              semesterEnd: semesterEnd,
              weekParity: card.weekParity,
            ),
          );
          break;
      }
      _removeDraft(card);
      _say('已入库：$title');
    } catch (e) {
      _say('入库失败：$e');
    }
  }

  void _removeDraft(DraftCard card) {
    setState(() => _drafts.remove(card));
    card.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 对话录入')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final message in _messages)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(message),
                    ),
                  ),
                for (final card in _drafts) _draftCard(card),
              ],
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                // 示例入口：新用户不知道能说什么，同时方便验收时一键填入。
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      ActionChip(
                        key: const Key('ai_sample_1'),
                        label: const Text('周五17点E栋104考试，周日交作业'),
                        onPressed: () =>
                            setState(() => _input.text = '周五17点E栋104考试，周日交作业'),
                      ),
                      const SizedBox(width: 8),
                      ActionChip(
                        key: const Key('ai_sample_2'),
                        label: const Text('12.03E栋103听讲座'),
                        onPressed: () =>
                            setState(() => _input.text = '12.03E栋103听讲座'),
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('ai_input'),
                        controller: _input,
                        decoration: const InputDecoration(
                          hintText: '例如：周五17点E栋104考试，周日交作业',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('ai_parse'),
                      onPressed: _busy ? null : _parse,
                      child: Text(_busy ? '解析中' : '解析'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _draftCard(DraftCard card) {
    final index = _drafts.indexOf(card) + 1;
    return Card(
      color: Colors.blue.shade50,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '草稿 $index（可修改后确认）',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  key: Key('ai_discard_$index'),
                  tooltip: '丢弃',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => _removeDraft(card),
                ),
              ],
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<DraftType>(
              initialValue: card.type,
              decoration: const InputDecoration(labelText: '类型'),
              items: const [
                DropdownMenuItem(value: DraftType.event, child: Text('事件')),
                DropdownMenuItem(value: DraftType.task, child: Text('任务')),
                DropdownMenuItem(value: DraftType.course, child: Text('课程')),
              ],
              onChanged: (value) =>
                  setState(() => card.type = value ?? DraftType.event),
            ),
            if (card.type == DraftType.course) ...[
              DropdownButtonFormField<int>(
                initialValue: card.dayOfWeek,
                decoration: const InputDecoration(labelText: '星期'),
                items: [
                  for (var i = 1; i <= 7; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text('周${'一二三四五六日'[i - 1]}'),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => card.dayOfWeek = value ?? 1),
              ),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('每周')),
                  ButtonSegment(value: 1, label: Text('单周')),
                  ButtonSegment(value: 2, label: Text('双周')),
                ],
                selected: {card.weekParity},
                onSelectionChanged: (value) =>
                    setState(() => card.weekParity = value.first),
              ),
            ],
            TextField(
              key: Key('ai_draft_title_$index'),
              controller: card.title,
              decoration: const InputDecoration(labelText: '事项'),
            ),
            TextField(
              key: Key('ai_draft_date_$index'),
              controller: card.date,
              decoration: const InputDecoration(labelText: '日期（yyyy-MM-dd）'),
            ),
            TextField(
              key: Key('ai_draft_time_$index'),
              controller: card.time,
              decoration: const InputDecoration(labelText: '时间（HH:mm，可空）'),
            ),
            if (card.type == DraftType.course)
              TextField(
                key: Key('ai_draft_end_time_$index'),
                controller: card.endTime,
                decoration: const InputDecoration(labelText: '结束时间（HH:mm）'),
              ),
            TextField(
              key: Key('ai_draft_location_$index'),
              controller: card.location,
              decoration: const InputDecoration(labelText: '地点'),
            ),
            TextField(
              key: Key('ai_draft_note_$index'),
              controller: card.note,
              decoration: const InputDecoration(labelText: '备注'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: Key('ai_confirm_$index'),
              onPressed: () => _confirmOne(card),
              child: const Text('确认入库'),
            ),
          ],
        ),
      ),
    );
  }
}
