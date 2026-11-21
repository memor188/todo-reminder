import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/models/course.dart';
import 'package:todo_app/models/event_item.dart';
import 'package:todo_app/models/task.dart';
import 'package:todo_app/services/backup_codec.dart';
import 'package:todo_app/services/settings_service.dart';

void main() {
  BackupData sample() => BackupData(
    courses: [
      Course(
        title: '高数',
        dayOfWeek: 1,
        startTime: '08:00',
        endTime: '09:40',
        semesterStart: '2026-11-01',
        semesterEnd: '2027-01-31',
      ),
    ],
    events: const [EventItem(title: '考试', startAt: '2026-11-23T17:00:00')],
    tasks: const [TaskItem(title: '取快递', dueDate: '2026-11-23')],
    config: {
      SettingsService.keyBaseUrl: 'https://api.deepseek.com',
      SettingsService.keyApiKey: 'sk-secret',
      SettingsService.keyModel: 'deepseek-chat',
    },
  );

  group('备份编解码', () {
    test('默认导出不含 API key，显式包含配置才写入', () {
      final plain = encodeBackup(sample());
      expect(plain.contains('sk-secret'), isFalse);
      expect(plain.contains('config'), isFalse);

      final withConfig = encodeBackup(sample(), includeConfig: true);
      expect(withConfig.contains('sk-secret'), isTrue);
    });

    test('往返后三类数据条数和字段一致', () {
      final decoded = decodeBackup(encodeBackup(sample(), includeConfig: true));
      expect(decoded.courses.length, 1);
      expect(decoded.events.single.title, '考试');
      expect(decoded.tasks.single.dueDate, '2026-11-23');
      expect(decoded.config[SettingsService.keyModel], 'deepseek-chat');
    });

    test('版本不兼容的备份被拒绝', () {
      expect(
        () => decodeBackup(
          '{"schema_version":99,"courses":[],"events":[],"tasks":[]}',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('字段缺失的备份被拒绝且异常信息可读', () {
      expect(
        () => decodeBackup(
          '{"schema_version":1,"courses":[{"title":"坏数据"}],"events":[],"tasks":[]}',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
