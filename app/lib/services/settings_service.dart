import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/period_table.dart';
import '../models/semester_plan.dart';

/// AI 供应商配置 + 学期方案：只存本地，不进业务表、不进默认备份。
class SettingsService {
  SettingsService([this._prefs]);

  final SharedPreferences? _prefs;
  final Map<String, String> _memory = {};

  /// 无插件环境下的内存模式，供 widget 测试注入替身。
  factory SettingsService.inMemory({
    String baseUrl = defaultBaseUrl,
    String apiKey = '',
    String model = defaultModel,
  }) {
    final service = SettingsService();
    service._memory.addAll({
      keyBaseUrl: baseUrl,
      keyApiKey: apiKey,
      keyModel: model,
    });
    return service;
  }

  static const String keyBaseUrl = 'ai_base_url';
  static const String keyApiKey = 'ai_api_key';
  static const String keyModel = 'ai_model';
  static const String keySemesterPlans = 'semester_plans';
  static const String keyPeriodTable = 'period_table';

  static const String defaultBaseUrl = 'https://api.deepseek.com';
  static const String defaultModel = 'deepseek-chat';

  static Future<SettingsService> load() async =>
      SettingsService(await SharedPreferences.getInstance());

  String get baseUrl =>
      _prefs?.getString(keyBaseUrl) ?? _memory[keyBaseUrl] ?? defaultBaseUrl;
  String get apiKey => _prefs?.getString(keyApiKey) ?? _memory[keyApiKey] ?? '';
  String get model =>
      _prefs?.getString(keyModel) ?? _memory[keyModel] ?? defaultModel;

  Map<String, String> toMap() => {
    keyBaseUrl: baseUrl,
    keyApiKey: apiKey,
    keyModel: model,
  };

  Future<void> save({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    final values = {
      keyBaseUrl: baseUrl.trim(),
      keyApiKey: apiKey.trim(),
      keyModel: model.trim(),
    };
    if (_prefs == null) {
      _memory.addAll(values);
      return;
    }
    await _prefs.setString(keyBaseUrl, values[keyBaseUrl]!);
    await _prefs.setString(keyApiKey, values[keyApiKey]!);
    await _prefs.setString(keyModel, values[keyModel]!);
  }

  Future<void> clear() async {
    if (_prefs == null) {
      _memory.remove(keyBaseUrl);
      _memory.remove(keyApiKey);
      _memory.remove(keyModel);
      return;
    }
    await _prefs.remove(keyBaseUrl);
    await _prefs.remove(keyApiKey);
    await _prefs.remove(keyModel);
  }

  /// 学期方案列表。存坏了按空处理，不让一条脏数据把录入页拖垮。
  List<SemesterPlan> get semesterPlans {
    final raw =
        _prefs?.getString(keySemesterPlans) ?? _memory[keySemesterPlans];
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) => SemesterPlan.fromMap(item.cast<String, dynamic>()))
          .whereType<SemesterPlan>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveSemesterPlans(List<SemesterPlan> plans) async {
    final raw = jsonEncode(plans.map((plan) => plan.toMap()).toList());
    if (_prefs == null) {
      _memory[keySemesterPlans] = raw;
      return;
    }
    await _prefs.setString(keySemesterPlans, raw);
  }

  /// 作息表（节次 → 钟点）。没存过或存坏了都回落到汕大默认值——
  /// 导入课表时宁可节次算错几节课，也不能因为一份脏配置整页打不开。
  PeriodTable get periodTable {
    final raw = _prefs?.getString(keyPeriodTable) ?? _memory[keyPeriodTable];
    if (raw == null || raw.isEmpty) return PeriodTable.shantouDefault;
    try {
      return PeriodTable.fromJson(jsonDecode(raw)) ??
          PeriodTable.shantouDefault;
    } catch (_) {
      return PeriodTable.shantouDefault;
    }
  }

  Future<void> savePeriodTable(PeriodTable table) async {
    final raw = jsonEncode(table.toJson());
    if (_prefs == null) {
      _memory[keyPeriodTable] = raw;
      return;
    }
    await _prefs.setString(keyPeriodTable, raw);
  }
}
