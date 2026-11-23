# v5 发布包（分发给朋友用）

2026-11-24 01:45 构建。这是**当前功能最全的一版**，可直接发给朋友全新安装。

## 安装包

`todo-v5-release.apk`

| 项 | 值 |
|---|---|
| 版本 | `5.0.0+5`（versionName / versionCode） |
| 包名 | `com.anlu.todo_app` |
| 架构 | **仅 arm64-v8a**（2017 年后的手机基本都支持；极老的 32 位机装不了） |
| 大小 | 20,154,371 字节（约 19.2 MB） |
| MD5 | `9604a4991b6f325a883b9f351135f8f9` |
| 签名 | 自建 key `CN=AnLu Todo`，APK Signature Scheme v2 |
| 编译 | AOT（`lib/arm64-v8a/libapp.so`，无 `kernel_blob.bin`） |

自查命令（在 `E:/todo-app` 下）：

```bash
APK=app/build/app/outputs/flutter-apk/app-release.apk
unzip -l "$APK" | grep -E 'libapp.so|kernel_blob'
apksigner.bat verify -v "$APK"          # 用 Android SDK build-tools 里的
aapt2 dump badging "$APK" | grep '^package:'
```

## 发给朋友时要说清楚的三件事

1. **安装**：微信/QQ 传 APK 后，安卓会拦「未知来源应用」，需要手动点「允许」。
   如果朋友手机装过别的签名同包名的版本，得先卸载再装。
2. **AI 功能要自己配 key**：DeepSeek 的 key 在「我的」页填，各用各的，
   **不要把你的 key 发给他**。包里没有硬编码 key（已 grep 源码和 assets 确认）。
   不配 key 也能用：手动录入、课表、提醒、备份都正常，只有 AI 对话/课表导入用不了。
3. **通知权限要手动给**：首次打开会弹权限请求，别拒绝；另外把 App 加进
   系统的**电池优化白名单**，否则后台待机时提醒可能被系统推迟或不响。

建议朋友装完后建一条 2 分钟后的待办，确认到点真的会响，再开始正式用。

## 和 debug 版的关系

**签名不同，不能覆盖安装。** 你的真机上继续用 debug 包（功能一样，只是 188MB、非 AOT）；
这个 release 包是给朋友全新安装用的。你自己要换成它的话：

1. App 内「我的 → 导出备份」（**不要勾「包含配置」**，避免明文 key 进备份文件）
2. `adb uninstall com.anlu.todo_app`
3. `adb install -r releases/v5-done/todo-v5-release.apk`
4. 「我的」里重填 AI 配置（baseURL / key / model）
5. 「我的 → 导入备份」恢复数据
6. 重新给通知权限 + 电池优化白名单
7. 建一条 2 分钟后的待办，确认提醒会响

## 这一版有什么

- 日程 / 课表双视图，左右滑动翻周，同一门课两页同色
- 课表左栏可切换：整点（8:00 / 10:00）↔ 节次（第 N 节 + 起止时刻）
- 课表课程块与象牙白背景融合、列间只有横线、「非本周」课灰着标出
- 课表导入：`.xls` 文件 / 截图识图 / 粘贴文字，本机换算节次
- 事件 / 任务 / 课程三类都能设提前提醒（0–60 分钟），课程按 8 周展开闹钟
- 震动默认、响铃可选；优先级标签；本地备份导出导入

## 重新构建

```bash
cd E:/todo-app/app/android
./gradlew assembleRelease --console=plain -Ptarget-platform=android-arm64
```

⚠️ 三个必须：
- **不加 `--offline`**（release 引擎包是手工拷进本地仓库的，离线模式索引查不到）
- **必须带 `-Ptarget-platform=android-arm64`**（本地仓库只有 arm64 release 包）
- 改版本号要同时改 `app/pubspec.yaml` 和 **`app/android/local.properties`**：
  `local.properties` 里的 `flutter.versionName` / `flutter.versionCode` 会**盖掉** pubspec 的值。
  只改 pubspec 会打出一个版本写着 1.0.0 的包——这次就踩到了，重打了一次。

构建偶尔 SIGTERM（内存压力），原样重跑一次即可。
