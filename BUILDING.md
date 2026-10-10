# 支线 0.1.1：构建与验证

仓库：[W-CLL/sidequest-app](https://github.com/W-CLL/sidequest-app)，默认分支 `main`。本轮目标是 Android debug APK，应用版本 `0.1.1+2`；没有部署公网 API、配置 release 签名或发布 GitHub Release。

## 开发环境

- Flutter **3.47.0 stable** / Dart **3.13.0**。
- Node.js **24.x**：服务端与真实 Flutter → Node 合约测试需要。
- JDK **21**、Android Gradle Plugin **9.1.0**、Gradle **9.3.1**。
- Android SDK Platform **36**、Build Tools **36.0.0**、NDK **28.2.13676358**；最低 Android **7.0 / API 24**。
- Gradle wrapper 固定官方 `bin` 分发包及 SHA-256。`local.properties`、生成文件、数据库、签名文件和构建产物不进入 Git。

首次构建需要访问 Flutter、pub.dev、Google Maven、Maven Central 与 Gradle 官方源。SDK 许可证应由环境所有者阅读并接受；项目不会自动运行接受许可证的命令。

## 本机构建

在仓库根目录运行：

```powershell
flutter pub get
flutter analyze
flutter test
node --test server/server.test.mjs
flutter build apk --debug --split-per-abi
```

合约测试优先使用 `SIDEQUEST_NODE`，未配置时使用 `PATH` 中的 `node`；不包含个人开发机路径。

三架构构建产物位于 `build/app/outputs/flutter-apk/`：

- `app-arm64-v8a-debug.apk`：多数较新的实体 Android 手机。
- `app-armeabi-v7a-debug.apk`：部分旧款 32 位 ARM 手机。
- `app-x86_64-debug.apk`：对应架构的模拟器。

Flutter 为拆分 APK 的 `versionCode` 自动添加架构偏移：本版 armv7 / arm64 / x86_64 分别为 `1002` / `2002` / `4002`，对应的客户端版本均为 `0.1.1+2`。

本轮交付副本保存在未跟踪的 `artifacts/v0.1.1/`，同时保存 SHA-256 和构建/签名核查记录；APK 不提交源码仓库。

```powershell
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk
```

默认没有 `API_BASE_URL`，运行本机模式。debug 签名由工具生成，不等于正式发布签名；另一台电脑或 GitHub runner 的 debug key 可能不同，覆盖安装前应核对签名并保护需要保留的数据。

### Windows 跨磁盘构建

如果 Pub 缓存和项目不在同一个磁盘，Kotlin 插件增量编译可能报 `this and base files have different roots`。本轮首次构建遇到这一环境问题，关闭本次进程的 Kotlin 增量编译后成功；无需修改项目配置、全局环境或清空缓存：

```powershell
$env:GRADLE_OPTS = ($env:GRADLE_OPTS + ' -Dorg.gradle.project.kotlin.incremental=false').Trim()
flutter build apk --debug --split-per-abi --no-pub
```

环境变量仅对当前 PowerShell 进程及其子进程生效。当前 `share_plus` 仍有未来 Flutter 版本不再支持旧 Kotlin 插件接入方式的构建警告；本版本构建通过，本轮没有顺带升级依赖。

## GitHub 检查与手动打包

- `Checks`：`main` 推送、PR 和手动触发时运行 Flutter analyze、Flutter test、Node 集成测试。
- `Android alpha APK`：只在 Actions 页面手动触发，使用固定 Flutter/JDK/Node 版本，检查通过后构建 debug APK 并保存 artifact 14 天。
- `api_base_url` 留空生成本机版；只接受无凭据的公开 HTTPS API 地址。该输入不会创建或部署服务器。
- `v0.1.0` 是初版源码基线；本轮完成的源码以 `v0.1.1` 标记。通过提交历史可以分别查看布局、文案和验证调整。

仓库未添加开源许可证；公开可见不代表已选择具体授权条款。

## 布局检查和截图

自动化布局测试覆盖：

- 390×844、默认字号、关闭键盘：检查主要内容与操作首屏可见。
- 360×640、320×568：允许垂直滚动，检查内容及操作可达。
- 390×844、1.3 与 2.0 倍字号：检查文字换行、卡片增长和操作可达。
- 约 300dp 键盘遮挡：检查登录输入、同意项、错误反馈与记录保存操作。
- 今日推荐/进行中/完成、登录前后“我的”，以及完整 16 条活动详情。

截图测试使用 Flutter 真实渲染和本机中文字体。Windows 默认读取系统微软雅黑；其他系统请设置 `SIDEQUEST_PREVIEW_FONT` 为本机可用的中文 TTF/TTC 字体路径。字体仅用于本地预览，不复制到仓库。

```powershell
flutter test test/preview_capture_test.dart --dart-define=CAPTURE_PREVIEWS=true
```

该命令更新 `screenshots/`，默认 `flutter test` 会跳过截图写入步骤。截图在 390×844 逻辑尺寸下以 2 倍像素输出。它们是开发预览，不代表 Android 真机、系统键盘、系统分享和导出面板已经验收。

## 可选远程服务

服务端启动与 HTTPS 部署见 [server/README.md](server/README.md)。仅在服务已经可访问时构建：

```powershell
flutter build apk --debug --split-per-abi --dart-define=API_BASE_URL=https://your-api.example.com
```

API 地址会编译进客户端，不能包含密码或令牌。单机数据不会自动迁移到远程账号。

USB 本机联调使用默认端口 8787：

```powershell
adb reverse tcp:8787 tcp:8787
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8787
```

Android debug 配置仅为 `127.0.0.1` 与 `localhost` 放行 HTTP；结束后可执行 `adb reverse --remove tcp:8787`。发布配置禁止明文 HTTP，iOS 使用系统默认 HTTPS 限制。

## 原生平台边界

应用显示名“支线”，包名保持 `app.sidequest.sidequest`。本轮没有新增定位、相机、麦克风、相册或通知权限。Android 关闭自动备份，并排除云备份和设备迁移中的应用数据；记录没有应用层加密。

没有连接 Android 实体手机时，安装、系统键盘、原生分享、文件导出和覆盖升级均仍需真机验收。iOS 工程保留，需要 macOS/Xcode 和有效签名配置后单独构建、测试。

## 本轮实际验证记录（2026-10-10）

| 检查 | 结果 |
| --- | --- |
| `flutter analyze --no-pub` | 通过，0 个问题 |
| `flutter test --no-pub --reporter expanded` | 32 项通过；1 项截图测试默认跳过；0 项失败 |
| `node --test server/server.test.mjs` | 10 项通过，0 项失败 |
| 显式启用 `CAPTURE_PREVIEWS` 的截图测试 | 1 项通过；生成并查看 14 张页面/状态预览和 16 张活动详情 |
| Android debug 分架构构建 | arm64、armv7、x86_64 均通过；最终构建包含密码要求与确认文案修正 |
| APK 签名与元信息 | 三包 `apksigner verify` 通过；应用名“支线”，包名 `app.sidequest.sidequest`，版本 `0.1.1`，min/target SDK 24/36 |
| Android 实体设备 | `adb devices` 无连接设备；没有声称真机验收通过 |

布局矩阵使用实际控件几何位置、滚动范围及 hit-test 验证可见和可点击；覆盖 16 条详情固定操作、小屏、大字号及 300dp 键盘 inset。键盘测试还实际输入昵称/密码、验证同意项及重复账号/错误密码反馈，并输入 300 字、验证第 301 字被拒绝、保存草稿。

本地 `artifacts/v0.1.1/` 保存 `flutter-analyze.log`、`flutter-test.log`、`node-test.log`、`preview-test.log`、`android-build.log`、`android-verification.log` 和 `SHA256SUMS`。以下哈希对应本次最终本机构建；其他环境重新构建的 debug APK 不保证字节一致。

```text
6e89aefee94965f8dc7dc78a813e2ca962456b06ba40a6b343032762f30ecf70  sidequest-android-v0.1.1-arm64.apk
ac74d2eedf43b906c99a4718f8bb29e34853ecd6b5ce5715f42f1057038cc6d1  sidequest-android-v0.1.1-armv7.apk
4ab7dd497664ffef033922f0a64b8773175587fa0ef83bf2eee4845d12a5755e  sidequest-android-v0.1.1-x86_64.apk
```
