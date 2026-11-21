import 'package:flutter/material.dart';

import '../models/semester_plan.dart';
import '../services/settings_service.dart';
import '../widgets/masked_formatters.dart';

/// 学期方案管理：增、改、删。
///
/// 2026-11-21 用户拍板放在「我的」页集中管理，而不是散落在录入页。
class SemesterPlansScreen extends StatefulWidget {
  const SemesterPlansScreen({super.key, required this.settings});

  final SettingsService settings;

  @override
  State<SemesterPlansScreen> createState() => _SemesterPlansScreenState();
}

class _SemesterPlansScreenState extends State<SemesterPlansScreen> {
  List<SemesterPlan> _plans = const [];

  @override
  void initState() {
    super.initState();
    _plans = widget.settings.semesterPlans;
  }

  Future<void> _persist(List<SemesterPlan> next) async {
    await widget.settings.saveSemesterPlans(next);
    if (!mounted) return;
    setState(() => _plans = next);
  }

  Future<void> _edit({SemesterPlan? plan}) async {
    final result = await showDialog<SemesterPlan>(
      context: context,
      builder: (context) => _PlanDialog(existing: plan),
    );
    if (result == null) return;
    final next = [..._plans];
    final index = next.indexWhere((item) => item.id == result.id);
    if (index >= 0) {
      next[index] = result;
    } else {
      next.add(result);
    }
    await _persist(next);
  }

  Future<void> _delete(SemesterPlan plan) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除方案'),
        content: Text('确定删除「${plan.name}」？已建好的课程不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm_delete_plan'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _persist(_plans.where((item) => item.id != plan.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('学期方案')),
      body: _plans.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '还没有方案。\n建一个「2026秋」，以后新建课程就能一键套用学期起止。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            )
          : ListView.separated(
              itemCount: _plans.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final plan = _plans[index];
                return ListTile(
                  key: Key('plan_${plan.id}'),
                  title: Text(plan.name),
                  subtitle: Text('${plan.start} ~ ${plan.end}'),
                  onTap: () => _edit(plan: plan),
                  trailing: IconButton(
                    key: Key('plan_delete_${plan.id}'),
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(plan),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        key: const Key('plan_add'),
        onPressed: () => _edit(),
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// 新建 / 编辑单个方案。返回 null 表示取消。
class _PlanDialog extends StatefulWidget {
  const _PlanDialog({this.existing});

  final SemesterPlan? existing;

  @override
  State<_PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends State<_PlanDialog> {
  late final TextEditingController _name;
  late final TextEditingController _start;
  late final TextEditingController _end;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _start = TextEditingController(text: existing?.start ?? '');
    _end = TextEditingController(text: existing?.end ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final start = _start.text.trim();
    final end = _end.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '给方案起个名字，比如「2026秋」');
      return;
    }
    final startDate = DateTime.tryParse(start);
    final endDate = DateTime.tryParse(end);
    if (startDate == null || endDate == null) {
      setState(() => _error = '起止日期各要 8 位数字，如 20260901');
      return;
    }
    if (endDate.isBefore(startDate)) {
      setState(() => _error = '结束日期不能早于开始日期');
      return;
    }
    final existing = widget.existing;
    Navigator.pop(
      context,
      existing == null
          ? SemesterPlan(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              name: name,
              start: start,
              end: end,
            )
          : existing.copyWith(name: name, start: start, end: end),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '新建学期方案' : '编辑学期方案'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('plan_name'),
            controller: _name,
            decoration: const InputDecoration(
              labelText: '方案名',
              hintText: '2026秋',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('plan_start'),
            controller: _start,
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
            key: const Key('plan_end'),
            controller: _end,
            keyboardType: TextInputType.number,
            inputFormatters: const [DateMaskFormatter()],
            decoration: const InputDecoration(
              labelText: '学期结束',
              hintText: '20270115',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
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
        FilledButton(
          key: const Key('plan_save'),
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
