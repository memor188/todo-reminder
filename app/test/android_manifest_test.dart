import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// release 包的网络权限回归（2026-11-28）。
///
/// Flutter 模板只给 debug/profile 的 Manifest 加 INTERNET 权限（hot reload 要用），
/// release 只看 main/AndroidManifest.xml。以前主 Manifest 漏了这条，debug 一切正常、
/// release 包所有网络请求被系统拒，报 "Failed host lookup" ——极易误判成 DNS 问题。
/// 真机一直用 debug 所以藏了很久，直到 release 装到平板上才发现。
void main() {
  test('主 Manifest 必须声明 INTERNET 权限', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml');
    expect(manifest.existsSync(), isTrue, reason: '主 Manifest 不该不存在');
    final content = manifest.readAsStringSync();
    expect(
      content,
      contains('android.permission.INTERNET'),
      reason: 'release 包要联网调 DeepSeek，缺 INTERNET 会 Failed host lookup',
    );
  });
}
