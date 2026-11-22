# 待办 · 课程表 App

一个 Android 端的待办与课程表应用。核心是**到点真的会响**的提醒，以及两种录入方式：手动填表，或者直接跟 AI 说一句话。

Flutter 写的，数据全部存在本机，不联网、不上传。

## 现在能做什么

**三种条目，混在一个时间线上**

- **课程**：周期规则（每周/单周/双周）+ 地点 + 颜色，管一整个学期
- **事件型待办**：考试、讲座、开会这种「到点必须在那」的
- **任务型待办**：写作业、取快递这种「当天做完就行」的

数据层分开存，显示层混排在一起。

**课表是周网格**

8:00 到 23:00，两小时一格。条目按真实起止时间铺在网格上（8:00–9:40 的课就占那一格约 5/6 的高度），时间重叠的自动并排平分宽度。

**AI 对话录入**

一句话能出多条草稿：

```
周五17点E栋104考试，周日交作业
```

→ 解析成两条，各自带日期时间地点，逐条确认才入库。

也能吞一长段微信公众号活动通知（带 emoji、报名链接、口号的），抽出「什么事、哪天、几点、在哪」，剩下的进备注。草稿只活在内存里，不确认就不写库。

供应商走 OpenAI 兼容接口，默认 DeepSeek，baseURL / apiKey / model 都能改。

**提醒**

本地通知，Importance 拉满 + `USAGE_ALARM` + `category=alarm`，锁屏可见，声音能绕过静音。重启后自动重新注册闹钟。

**输入体验**

日期时间只敲数字，横杠冒号自动补（`20261121` → `2026-11-21`）。学期起止存成「方案」，新建课程一键套用，按当前日期自动选中学期。

**备份**

导出 JSON 走系统分享，恢复是覆盖式且失败会整体回滚。

## 技术栈

| 层 | 选型 |
|---|---|
| 框架 | Flutter 3.50 / Dart 3.14 |
| 存储 | `sqflite`（本地 SQLite）+ `shared_preferences`（配置） |
| 通知 | `flutter_local_notifications` 23.x，`timezone` 定时 |
| 网络 | `http`，只用于 AI 接口 |

## 本地构建

需要 JDK 17、Flutter SDK、Android 命令行 SDK（不需要 Android Studio）。

```bash
cd app
flutter pub get
cd android
# debug（日常开发用，~188MB，带 JIT 快照和热重载）
./gradlew assembleDebug --console=plain --offline
# 产物：app/build/app/outputs/flutter-apk/app-debug.apk

# release（给朋友装 / 备份用，~19MB，AOT 编译）
./gradlew assembleRelease --console=plain -Ptarget-platform=android-arm64
# 产物：app/build/app/outputs/flutter-apk/app-release.apk
```

离线构建依赖本机 maven 仓库（`E:\AndroidDev\local-maven`）里的 Flutter engine jar。

两个坑：

1. `exclusiveContent` 那段必须放在**根工程** `android/build.gradle.kts` 的 `allprojects` 里。只写在 `app/build.gradle.kts` 里，插件子工程（`android_file_picker`、`sqflite_android` 等）解析 `io.flutter:flutter_embedding_release` 时仍会跑去 `storage.googleapis.com`，在慢速网络下表现为卡住。
2. `assembleRelease` **不要加 `--offline`**。release 版的 engine 包是新加进本地仓库的，Gradle 的模块索引还没登记，离线模式下会直接报 `No cached version available for offline mode`。不带 `--offline` 时 `io.flutter` 被锁定在 `file://` 本地仓库，解析全在磁盘上完成，不会联网。

## 测试

```bash
cd app
flutter test       # 75 个用例
flutter analyze    # 应为 0 问题
```

覆盖了时间线合并排序、课表网格布局、单双周判定、AI 返回值的各种畸形形态、备份编解码、掩码输入、学期方案选取，以及主要页面的交互。

## 目录

```
app/lib/
  models/      数据模型 + 时间线合并 + 网格布局算法
  screens/     日程 / 课表 / 录入 / AI 对话 / 设置 / 学期方案
  services/    数据库、通知、AI、配置、备份编解码
  widgets/     时间线条目、掩码输入器
docs/          需求规格、开发计划（含各阶段验收记录与踩坑）
tools/         AI 提示词回归脚本、GitHub 上传脚本
```

## 进度

| 版本 | 内容 | tag |
|---|---|---|
| V0 | 空壳 + 通知链路跑通 | `v0-done` |
| V1 | 日程列表 + 本地存储 + 手动录入 + 备份恢复 | `v1-done` |
| V2 | 课表周网格 + 单双周 + AI 多草稿 + 硬提醒 + 条目增删改 + 掩码输入 + 学期方案 | `v2-done` |
| V3 | 课程导入（粘贴课表让 AI 解析）、提前量、贪睡、优先级 | 未开始 |

## 已知限制

- **只有 Android**。iOS 没做，因为编译需要 Mac。
- **国产 ROM 的后台冻结是系统级限制**。vivo / 小米 / 华为需要在设置里手动加白名单（App 内「我的」页有指引），否则长息屏后提醒可能不准。这是所有国产安卓 App 的共同问题，绕不过去。
- 提醒是「终态硬提醒」的简化版，V3 才做提前量和贪睡。
