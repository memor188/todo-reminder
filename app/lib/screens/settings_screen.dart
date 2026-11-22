import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/backup_codec.dart';
import '../services/db_service.dart';
import '../services/notification_service.dart';
import '../services/settings_service.dart';
import 'ai_chat_screen.dart';
import 'period_table_screen.dart';
import 'semester_plans_screen.dart';
import 'timetable_import_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.db,
    required this.notifications,
    this.onDataChanged,
  });

  final SettingsService settings;
  final DbService db;
  final NotificationService notifications;
  final VoidCallback? onDataChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _model = TextEditingController();
  bool _includeConfig = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = widget.settings;
    _baseUrl.text = settings.baseUrl;
    _apiKey.text = settings.apiKey;
    _model.text = settings.model;
    if (!mounted) return;
    setState(() => _loading = false);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _openAiChat() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AiChatScreen(
          settings: widget.settings,
          db: widget.db,
          notifications: widget.notifications,
        ),
      ),
    );
  }

  void _openSemesterPlans() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SemesterPlansScreen(settings: widget.settings),
      ),
    );
  }

  void _openPeriodTable() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => PeriodTableScreen(settings: widget.settings),
      ),
    );
  }

  Future<void> _openTimetableImport() async {
    final imported = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) =>
            TimetableImportScreen(settings: widget.settings, db: widget.db),
      ),
    );
    if (imported == true) widget.onDataChanged?.call();
  }

  Future<void> _save() async {
    await widget.settings.save(
      baseUrl: _baseUrl.text,
      apiKey: _apiKey.text,
      model: _model.text,
    );
    _toast('配置已保存');
  }

  Future<void> _clear() async {
    await widget.settings.clear();
    _baseUrl.clear();
    _apiKey.clear();
    _model.clear();
    _toast('配置已清除');
  }

  Future<void> _export() async {
    try {
      final data = await widget.db.exportData();
      final json = encodeBackup(data, includeConfig: _includeConfig);
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${dir.path}/todo_backup_$stamp.json');
      await file.writeAsString(json);
      await Share.shareXFiles([
        XFile(file.path, mimeType: 'application/json'),
      ], subject: '待办 App 备份');
      _toast(_includeConfig ? '已导出（含配置，API key 明文）' : '已导出（不含 API key）');
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  Future<void> _import() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      final path = file?.path;
      if (path == null) return;
      final decoded = decodeBackup(await File(path).readAsString());
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认覆盖恢复'),
          content: const Text('将覆盖当前所有课程、事件和任务，且不可撤销。确定继续？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('覆盖恢复'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await widget.db.restore(decoded);
      if (decoded.config.isNotEmpty) {
        await widget.settings.save(
          baseUrl: decoded.config[SettingsService.keyBaseUrl] ?? '',
          apiKey: decoded.config[SettingsService.keyApiKey] ?? '',
          model: decoded.config[SettingsService.keyModel] ?? '',
        );
        await _load();
      }
      widget.onDataChanged?.call();
      _toast(
        '恢复成功：${decoded.courses.length} 课程 / '
        '${decoded.events.length} 事件 / ${decoded.tasks.length} 任务',
      );
    } on FormatException catch (e) {
      _toast('导入失败：${e.message}（原数据未改动）');
    } catch (e) {
      _toast('导入失败：$e（原数据未改动）');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FilledButton.tonal(
          key: const Key('settings_ai_chat'),
          onPressed: _openAiChat,
          child: const Text('AI 对话录入'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const Key('settings_semester_plans'),
          onPressed: _openSemesterPlans,
          child: const Text('学期方案（新建课程时一键套用）'),
        ),
        OutlinedButton(
          key: const Key('settings_period_table'),
          onPressed: _openPeriodTable,
          child: const Text('作息表（课表导入时按它换算节次时间）'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const Key('settings_timetable_import'),
          onPressed: _openTimetableImport,
          child: const Text('课表导入（丢 .xls 文件 / 截图 / 粘贴文字）'),
        ),
        const SizedBox(height: 12),
        const Text(
          'AI 供应商（OpenAI 兼容）',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('settings_base'),
          controller: _baseUrl,
          decoration: const InputDecoration(
            labelText: 'baseURL',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('settings_key'),
          controller: _apiKey,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'API key',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('settings_model'),
          controller: _model,
          decoration: const InputDecoration(
            labelText: 'model',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                key: const Key('settings_save'),
                onPressed: _save,
                child: const Text('保存'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                key: const Key('settings_clear'),
                onPressed: _clear,
                child: const Text('清除'),
              ),
            ),
          ],
        ),
        const Divider(height: 32),
        const Text(
          '备份与恢复',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        CheckboxListTile(
          value: _includeConfig,
          onChanged: (value) => setState(() => _includeConfig = value ?? false),
          title: const Text('包含配置（API key 明文写入，谨慎分享）'),
        ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('settings_export'),
                onPressed: _export,
                child: const Text('导出备份'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                key: const Key('settings_import'),
                onPressed: _import,
                child: const Text('覆盖恢复'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          '默认备份不含 API key；恢复为覆盖式，失败会整体回滚。',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
        const Divider(height: 32),
        const ExpansionTile(
          title: Text('后台提醒白名单指引（国产 ROM）'),
          children: [
            Text(
              'OriginOS（iQOO/vivo）：设置搜索「自启动」开启 → 近期任务卡片下滑加锁 → '
              '设置搜索「后台耗电管理」允许后台高耗电；关掉睡眠模式与超级省电。',
            ),
            SizedBox(height: 8),
            Text(
              'MIUI（小米/红米）：设置 → 应用设置 → 应用管理 → 本 App → '
              '省电策略选「无限制」；自启动开启；锁定近期任务卡片。',
            ),
            SizedBox(height: 8),
            Text(
              'EMUI/HarmonyOS（华为）：设置 → 应用 → 应用启动管理 → 本 App 关自动管理，'
              '手动允许自启动/关联启动/后台活动；受保护应用加入白名单。',
            ),
            SizedBox(height: 8),
            Text('国产 ROM 冻结是系统级限制，无法保证所有机型都准时提醒。'),
          ],
        ),
      ],
    );
  }
}
