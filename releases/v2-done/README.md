# v2-done 备份

2026-11-22 12:12 打的检查点。V2 阶段收尾，可随时回滚到这里。

## 对应代码

| 项 | 值 |
|---|---|
| Git tag | `v2-done` |
| 提交 | `f2886e0`（docs: 补 3.8 掩码输入与学期方案的真机验收记录） |
| 测试 | 75 个全过，`flutter analyze` 0 问题 |
| 包名 | `com.anlu.todo_app` |

## 安装包

### debug 版（日常调试用）

`todo-v2-done-debug.apk`（约 188 MB，含全部 ABI，带 JIT 快照）

```
MD5  57d370ed206e7d10b51e4df7b1a91654
```

重装：`adb install -r -g todo-v2-done-debug.apk`
（手机锁屏时 vivo 会拦安装确认框，报 `User rejected permissions`，先解锁。）

### release 版（分发/长期用）

`todo-v2-done-release.apk`（18.9 MB，仅 arm64-v8a，AOT 编译，自建 key 签名 `CN=AnLu Todo`）

```
MD5  5091a0c4979ffcdf7cd3ceeecbe490be
大小 19,826,687 字节
```

⚠️ **和 debug 版签名不同，不能覆盖安装。** 直接 `adb install -r` 会报
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`。换装流程：

1. 先在现有 App 里「我的 → 导出备份」（不含 API key 的 JSON）
2. `adb uninstall com.anlu.todo_app`
3. `adb install -r todo-v2-done-release.apk`
4. 重新填 AI 配置 + 导入备份
5. **复验通知权限**（release 是全新安装，通知权限和电池优化白名单要重新给）

> 这套流程留到 V3 收尾时再走，现在只证明 release 链路是通的、包是能出来的。

## 这一版包含什么

- V1 基础：日程列表、手动录入、本地存储、备份导出/覆盖恢复
- V2 核心：课表周网格、单双周、AI 对话多草稿录入、硬提醒（响铃+锁屏可见）、开机重注册、国产 ROM 白名单指引
- 增补：条目编辑/删除（日程和课表都能点进去）、AI 长文本活动通知解析、课表 8:00–23:00 两小时一格、条目按真实起止时间铺满网格
- 输入体验：日期时间只敲数字（分隔符自动补）、学期方案（新建课程一键套用学期起止）

## 重新构建这一版

```bash
cd E:/todo-app/app/android

# debug
./gradlew assembleDebug --console=plain --offline
# 产物：app/build/app/outputs/flutter-apk/app-debug.apk

# release
./gradlew assembleRelease --console=plain -Ptarget-platform=android-arm64
# 产物：app/build/app/outputs/flutter-apk/app-release.apk
```

两个注意：

- 离线构建依赖 `E:/AndroidDev/local-maven`（`io.flutter` 的 engine jar 本地仓库）。`exclusiveContent` 那段现在在**根工程** `android/build.gradle.kts` 的 `allprojects` 里，别只往 `app/build.gradle.kts` 挪——插件子工程也要用。
- `assembleRelease` **不要加 `--offline`**（本地仓库里 release 的包没登记进 Gradle 索引，离线模式会报 `No cached version`），也**必须带** `-Ptarget-platform=android-arm64`（本地仓库只有 arm64 的 release engine）。

细节见 `docs/开发计划.md` 的 §2.8.1。

## 回滚

```bash
git checkout v2-done     # 只看
git reset --hard v2-done # 真正回到这里（会丢弃之后的提交）
```
