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

`todo-v2-done-debug.apk`（约 188 MB，debug 版，含全部 ABI）

```
MD5  57d370ed206e7d10b51e4df7b1a91654
```

重装：`adb install -r -g todo-v2-done-debug.apk`
（手机锁屏时 vivo 会拦安装确认框，报 `User rejected permissions`，先解锁。）

## 这一版包含什么

- V1 基础：日程列表、手动录入、本地存储、备份导出/覆盖恢复
- V2 核心：课表周网格、单双周、AI 对话多草稿录入、硬提醒（响铃+锁屏可见）、开机重注册、国产 ROM 白名单指引
- 增补：条目编辑/删除（日程和课表都能点进去）、AI 长文本活动通知解析、课表 8:00–23:00 两小时一格、条目按真实起止时间铺满网格
- 输入体验：日期时间只敲数字（分隔符自动补）、学期方案（新建课程一键套用学期起止）

## 重新构建这一版

```bash
cd E:/todo-app/app/android
./gradlew assembleDebug --console=plain --offline
# 产物：app/build/app/outputs/flutter-apk/app-debug.apk
```

离线构建依赖 `E:/AndroidDev/local-maven`（`io.flutter` 的 engine jar 本地仓库）。
不要删 `app/build.gradle.kts` 里的 `exclusiveContent` 那段，删了会去 40KB/s 的官方源重下 427MB。

## 回滚

```bash
git checkout v2-done     # 只看
git reset --hard v2-done # 真正回到这里（会丢弃之后的提交）
```
