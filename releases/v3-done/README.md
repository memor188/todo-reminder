# v3-done 备份

2026-11-22 20:20 打的检查点。V3 阶段收尾，可随时回滚到这里。

## 对应代码

| 项 | 值 |
|---|---|
| Git tag | `v3-done` |
| 提交 | `88f8fb9`（feat(v3): 优先级标签，数据库升到 v4）之后 |
| 版本 | `3.0.0+3`（versionName / versionCode） |
| 测试 | **182 个全过**，`flutter analyze` 0 问题 |
| 数据库版本 | 4（v1 courses.note → v3 提前量 → v4 优先级） |
| 包名 | `com.anlu.todo_app` |

## 安装包

### release 版（分发/长期用）

`todo-v3-done-release.apk`（19.96 MB，仅 arm64-v8a，AOT 编译，自建 key 签名 `CN=AnLu Todo`）

```
MD5  93762e61c61bc7e5d270e3368d90ff42
大小 19,957,759 字节
```

自查：`unzip -l` 里有 `lib/arm64-v8a/libapp.so`（AOT 快照），**没有** `kernel_blob.bin`；
`apksigner verify -v` 输出 `Verifies` + v2 scheme true。

⚠️ **和 debug 版签名不同，不能覆盖安装。** 直接 `adb install -r` 会报
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`。换装流程（**会清数据，务必先导出备份**）：

1. 现有 App 里「我的 → 导出备份」（选不勾「包含配置」，避免明文 key 外流）
2. `adb uninstall com.anlu.todo_app`
3. `adb install -r todo-v3-done-release.apk`
4. 「我的」里重填 AI 配置（baseURL / key / model）
5. 「我的 → 导入备份」恢复课程、事件、任务
6. **复验通知权限 + 电池优化白名单**（release 是全新安装，这些要重新给）
7. 随便建一条 2 分钟后的待办，确认到点会响——**这是换装后唯一必须复验的功能**

> debug 包没有归档（188 MB）：`cd app/android && ./gradlew assembleDebug --console=plain --offline` 随时能重建。

## 这一版比 v2-done 多了什么

- **提醒提前量**：事件/任务可选提前 0–60 分钟；正文按「实际剩余时间」写，不按配置值
- **课表 AI 导入**：粘贴课表文字 → AI 拆成「周几 + 第几节」 → 本机作息表换算钟点 → 预览勾选入库
- **作息表**：13 小节可逐节改（第 10 节写作「0」，晚上三节写作 A/B/C）
- **课程提醒**：把课程规则按未来 8 周展开成一次性闹钟（单双周、学期边界都算），正文带教室
- **提醒自愈**：启动 / 恢复备份 / 导入课表后整体重排，修掉「库里改了、闹钟没跟上」
- **优先级标签**：普通/重要/紧急，只做视觉标记不排序

## 重新构建这一版

```bash
cd E:/todo-app/app/android

# debug
./gradlew assembleDebug --console=plain --offline
# release
./gradlew assembleRelease --console=plain -Ptarget-platform=android-arm64
```

两个注意（沿用 v2-done）：

- 离线构建依赖 `E:/AndroidDev/local-maven`，`exclusiveContent` 必须在**根工程** `android/build.gradle.kts` 的 `allprojects` 里。
- `assembleRelease` **不要加 `--offline`**，**必须带** `-Ptarget-platform=android-arm64`。
- 构建偶尔会被 SIGTERM 打断（内存压力），**原样重跑一次即可**，别急着查依赖。

## 回滚

```bash
git checkout v3-done     # 只看
git reset --hard v3-done # 真正回到这里（会丢弃之后的提交）
```
