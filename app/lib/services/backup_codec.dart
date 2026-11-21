import 'dart:convert';

import '../models/course.dart';
import '../models/event_item.dart';
import '../models/task.dart';

const int backupSchemaVersion = 1;

/// 备份数据的内存表示。config 只有在用户显式勾选「包含配置」时才非空。
class BackupData {
  const BackupData({
    required this.courses,
    required this.events,
    required this.tasks,
    this.config = const {},
  });

  final List<Course> courses;
  final List<EventItem> events;
  final List<TaskItem> tasks;
  final Map<String, String> config;
}

/// 导出：默认绝不写 API key，只有 includeConfig=true 才带配置。
String encodeBackup(BackupData data, {bool includeConfig = false}) {
  final payload = <String, Object?>{
    'schema_version': backupSchemaVersion,
    'exported_at': DateTime.now().toIso8601String(),
    'courses': data.courses.map((e) => e.toMap()).toList(),
    'events': data.events.map((e) => e.toMap()).toList(),
    'tasks': data.tasks.map((e) => e.toMap()).toList(),
    if (includeConfig) 'config': data.config,
  };
  return const JsonEncoder.withIndent('  ').convert(payload);
}

/// 导入：严格校验，坏文件直接抛 FormatException，调用方保证原数据不变。
BackupData decodeBackup(String source) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    throw const FormatException('备份文件不是合法 JSON');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('备份文件顶层必须是对象');
  }
  final root = decoded;
  if (root['schema_version'] != backupSchemaVersion) {
    throw const FormatException('备份版本不兼容');
  }

  List<Map<String, Object?>> rows(String key) {
    final value = root[key];
    if (value is! List) throw FormatException('备份缺少 $key 列表');
    return value.map((e) {
      if (e is! Map) throw FormatException('$key 中存在非法记录');
      return e.map((k, v) => MapEntry(k.toString(), v));
    }).toList();
  }

  try {
    final configRaw = root['config'];
    final config = <String, String>{};
    if (configRaw is Map) {
      configRaw.forEach((k, v) {
        if (v != null) config[k.toString()] = v.toString();
      });
    }
    return BackupData(
      courses: rows('courses').map(Course.fromMap).toList(),
      events: rows('events').map(EventItem.fromMap).toList(),
      tasks: rows('tasks').map(TaskItem.fromMap).toList(),
      config: config,
    );
  } on FormatException {
    rethrow;
  } catch (e) {
    throw FormatException('备份字段不完整：$e');
  }
}
