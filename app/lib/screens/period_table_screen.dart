import 'package:flutter/material.dart';

import '../models/period_table.dart';
import '../models/timeline.dart';
import '../services/settings_service.dart';
import '../widgets/masked_formatters.dart';

/// 作息表管理：把「第几节」换算成钟点。
///
/// 课表原文只写节次（「345」= 第 3~5 节），不写钟点，所以这张表是课表导入
/// 正确性的地基。默认值是汕头大学官方作息（2026-11-22 用户提供），换学校
/// 或学校改了作息，在这里改即可。
class PeriodTableScreen extends StatefulWidget {
  const PeriodTableScreen({super.key, required this.settings});

  final SettingsService settings;

  @override
  State<PeriodTableScreen> createState() => _PeriodTableScreenState();
}

class _PeriodTableScreenState extends State<PeriodTableScreen> {
  late PeriodTable _table;

  @override
  void initState() {
    super.initState();
    _table = widget.settings.periodTable;
  }

  Future<void> _persist(PeriodTable next) async {
    await widget.settings.savePeriodTable(next);
    if (!mounted) return;
    setState(() => _table = next);
  }

  Future<void> _edit(PeriodSlot slot) async {
    final result = await showDialog<PeriodSlot>(
      context: context,
      builder: (context) => _SlotDialog(existing: slot),
    );
    if (result == null) return;
    final next = [
      for (final item in _table.slots)
        if (item.label == slot.label) result else item,
    ];
    await _persist(PeriodTable(next));
  }

  Future<void> _restoreDefault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复默认作息'),
        content: const Text('将把全部节次时间改回汕头大学默认值。已建好的课程不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('confirm_restore_periods'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _persist(PeriodTable.shantouDefault);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('作息表'),
        actions: [
          IconButton(
            key: const Key('restore_period_defaults'),
            tooltip: '恢复默认',
            onPressed: _restoreDefault,
            icon: const Icon(Icons.restore),
          ),
        ],
      ),
      body: ListView.separated(
        itemCount: _table.slots.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final slot = _table.slots[index];
          return ListTile(
            key: Key('period_row_${slot.label}'),
            title: Text('第 ${slot.label} 节'),
            subtitle: Text('${slot.start} – ${slot.end}'),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: () => _edit(slot),
          );
        },
      ),
    );
  }
}

class _SlotDialog extends StatefulWidget {
  const _SlotDialog({required this.existing});

  final PeriodSlot existing;

  @override
  State<_SlotDialog> createState() => _SlotDialogState();
}

class _SlotDialogState extends State<_SlotDialog> {
  late final TextEditingController _start;
  late final TextEditingController _end;
  String? _message;

  @override
  void initState() {
    super.initState();
    _start = TextEditingController(text: widget.existing.start);
    _end = TextEditingController(text: widget.existing.end);
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
      setState(() => _message = '时间格式应为 HH:mm，只敲数字也行');
      return;
    }
    if (end <= start) {
      setState(() => _message = '结束时间要晚于开始时间');
      return;
    }
    Navigator.pop(
      context,
      PeriodSlot(
        label: widget.existing.label,
        start: hm(start),
        end: hm(end),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('第 ${widget.existing.label} 节'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('period_start'),
            controller: _start,
            keyboardType: TextInputType.number,
            inputFormatters: const [TimeMaskFormatter()],
            decoration: const InputDecoration(
              labelText: '开始',
              hintText: '0800',
              helperText: '只敲数字，冒号自动补',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('period_end'),
            controller: _end,
            keyboardType: TextInputType.number,
            inputFormatters: const [TimeMaskFormatter()],
            decoration: const InputDecoration(
              labelText: '结束',
              hintText: '0845',
              border: OutlineInputBorder(),
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _message!,
                key: const Key('period_message'),
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
          key: const Key('save_period'),
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
