import 'package:shared_preferences/shared_preferences.dart';

/// AI 供应商配置：只存本地，不进业务表、不进默认备份。
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
}
