/// 只管「排一条提醒 / 撤一条提醒」的最小协议。
///
/// 抽出来是为了让排程逻辑能脱离平台通道被测到：生产实现是
/// [NotificationService]（真下发到 Android 闹钟），测试里换成记录调用的假实现，
/// 就能断言「某门课未来 8 周排了哪几条、几点几分、正文写了什么」。
abstract class ReminderSink {
  Future<void> schedule({
    required int id,
    required String title,
    required String body,
    required DateTime eventTime,
  });

  Future<void> cancel(int id);
}
