# 支线 0.2.0：构建与本地联调

仓库：[W-CLL/sidequest-app](https://github.com/W-CLL/sidequest-app)。目标版本 `0.2.0+3`，Android debug 包；无公网部署、无 release 签名、无自动 GitHub Release。

## 环境

- Flutter **3.47.0 stable** / Dart **3.13.0**。
- Node.js **24.x**（内置 SQLite）。
- FFmpeg / FFprobe：必须支持 H.264、AAC、JPEG；服务启动时检查。通过 `PATH` 或 `FFMPEG_PATH` / `FFPROBE_PATH` 配置，不把本机路径写入源码。
- Java **21**、Android SDK Platform **36** / Build Tools **36.0.0** / NDK **28.2.13676358**；最低 API **24**。
- AGP **9.1.0**、Gradle **9.3.1**；wrapper 校验固定。构建缓存、数据库、媒体、备份、环境文件、APK 和签名文件不进入 Git。

首次构建需要访问 Flutter、pub、GitHub 原生 SQLite 构件和 Maven/Gradle 源。SDK 许可证须由环境所有者阅读并接受；项目不自动接受许可证。

## 本地服务与 Android

从项目根目录运行检查：

```powershell
flutter pub get
node scripts/generate-catalog.mjs --check
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
node --test server/server.test.mjs server/media.test.mjs server/catalog.test.mjs
```

真实 Flutter → Node 合约测试优先使用 `SIDEQUEST_NODE`，否则使用 `PATH` 的 `node`。测试使用临时数据库/媒体；真实转换测试需要真实 FFmpeg，不以模拟转换代替。

启动单进程本地 API（独立 v2 数据目录，不复用旧库）：

```powershell
$env:DATABASE_PATH = Join-Path $PWD '.runtime/v0.2/sidequest-v2.sqlite'
$env:MEDIA_DIRECTORY = Join-Path $PWD '.runtime/v0.2/media'
node server/server.mjs
```

默认只监听 `127.0.0.1:8787`，健康检查 `/api/health` 应返回 `protocolVersion: 2`。不要在已启动服务时对同一数据目录再启动服务或进行备份。详细说明见 [server/README.md](server/README.md)。

在另一终端安装/运行：

```powershell
adb reverse tcp:8787 tcp:8787
flutter build apk --debug --split-per-abi --dart-define=API_BASE_URL=http://127.0.0.1:8787
adb shell getprop ro.product.cpu.abi
# 按上一步 ABI 选择安装包；以下示例适用于 arm64-v8a。
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk
```

联调结束可执行 `adb reverse --remove tcp:8787`。debug 网络配置只允许 `127.0.0.1` 和 `localhost` 明文；不要将此包当作公网可用客户端，也不要用敏感记录测试。模拟器同样可使用 `adb reverse`，不默认放开 `10.0.2.2` 或整个局域网明文。

客户端没有 `API_BASE_URL` 时显示配置错误。正式远程地址需 HTTPS，URL 不得携带账号、令牌或密码，不加 `/api` 后缀。配置 URL 不会自动创建或部署服务器。

拆分 APK 输出：

- `build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk`
- `build/app/outputs/flutter-apk/app-armeabi-v7a-debug.apk`
- `build/app/outputs/flutter-apk/app-x86_64-debug.apk`

按设备 ABI 选择对应文件；常见 x86_64 模拟器应使用 x86_64 包。对应 Android versionCode 为 2003 / 1003 / 4003。debug key 因环境而异；覆盖安装前核对签名并保护原数据。新版本不迁移旧本机账号，不自动删除旧数据文件。

### Windows 环境提示

Pub 缓存和项目跨磁盘时，若 Kotlin 报 `this and base files have different roots`，可只为本次终端禁用增量编译，不清空用户缓存：

```powershell
$env:GRADLE_OPTS = ($env:GRADLE_OPTS + ' -Dorg.gradle.project.kotlin.incremental=false').Trim()
flutter build apk --debug --split-per-abi --no-pub --dart-define=API_BASE_URL=http://127.0.0.1:8787
```

SQLite 测试原生库由依赖的构建钩子下载并校验 SHA-256。网络受限时可仅为当前进程配置已获授权的 `HTTP_PROXY` / `HTTPS_PROXY`，不能跳过证书或构件校验；不把个人代理配置提交仓库。

若 Android Studio 使用较新的内置 JDK，本轮可在当前进程将 `JAVA_HOME` 指向已安装的 JDK 21；不需要修改全局 Java 配置。

## Web 版（浏览器 / iOS 主屏幕）

网页版与安卓版共用同一套界面与接口，编译为在线优先客户端：会话用服务端下发的 HttpOnly Cookie，草稿直接存服务端（`/api/draft`），没有本地数据库与后台同步。安卓版离线 + 同步架构不受影响。

```powershell
flutter pub get
flutter build web --release --no-web-resources-cdn                    # 本地自测
flutter build web --release --base-href /app/ --no-web-resources-cdn  # 线上部署形态（见 server/DEPLOY.md 附录）
```

说明：`--no-web-resources-cdn` 把图形引擎（CanvasKit）本地化；缺字回退字体（中文等）由自定义 `web/flutter_bootstrap.js` 指向线上镜像（`/app/webfonts/`）——运行期完全不依赖 Google CDN（国内网络可达性见 server/DEPLOY.md 附录「白屏根因修复」）。

本地联调（保持同源，Cookie 与 Origin 行为与线上一致）：

```powershell
# 终端 A：API —— 把页面来源加入允许列表
$env:DATABASE_PATH = Join-Path $PWD '.runtime/v0.2/sidequest-v2.sqlite'
$env:MEDIA_DIRECTORY = Join-Path $PWD '.runtime/v0.2/media'
$env:ALLOWED_ORIGINS = 'http://127.0.0.1:8080'
node server/server.mjs
# 终端 B：静态托管 + /api 反向代理
node scripts/serve-web.mjs
```

浏览器打开 `http://127.0.0.1:8080`。说明：网页版不需要 `API_BASE_URL`（同源调用）；媒体先支持图片（视频/语音请在手机端记录）；关闭/刷新页面时若有未保存草稿，浏览器会给出通用离开确认。`flutter run -d chrome` 只适合纯界面调试——跨端口不共享 Cookie，端到端联调请用上面的同源方式。

## CI

`Checks` 覆盖目录一致性、Flutter analyze、Flutter（含真实 API）测试、Node 集成与真实媒体转换。CI 安装 FFmpeg。

`Android alpha APK` 只手动触发，`api_base_url` 必填且必须为无凭据的公开 HTTPS 地址；产生 APK 和 SHA-256 artifact，保留 14 天，不发布 Release。本轮没有可填入的已部署公网服务；本地联调包由上面的本机命令生成。

## 截图与验证边界

```powershell
flutter test test/preview_capture_test.dart --dart-define=CAPTURE_PREVIEWS=true
```

截图使用本机中文字体，Windows 默认为微软雅黑，其他系统通过 `SIDEQUEST_PREVIEW_FONT` 指定中文 TTF/TTC。字体不入库。390×844 逻辑尺寸、2 倍输出；默认测试跳过截图写入。

布局测试覆盖常规屏、小屏、1.3/2.0 倍字号和键盘 inset；媒体长列表允许滚动。它们不能验证 Android 系统相册、真实麦克风、硬件解码、电话中断、进程被杀后的 picker 恢复、重启及电池优化下的后台任务。

本轮静态检查、113 项 Flutter 测试、32 项 Node 测试及三架构 debug 构建通过；9 项真实 API 合约另行执行通过。完整结果、签名/哈希及真机待验项见 [docs/v0.2-validation.md](docs/v0.2-validation.md)。APK、日志、SHA-256 的本地交付副本保存在未跟踪的 `artifacts/v0.2.0/`，文件名为 `sidequest-0.2.0-<ABI>-debug.apk`；校验清单为 `SHA256SUMS.txt`。构建通过不代表真机验收。

## 隐私与运维

Android 新增录音和网络状态权限；图片/视频使用系统选择器，不请求相机或全相册访问。iOS 仅补充相册/麦克风用途描述，未进行 iOS 构建。Android 自动备份仍关闭。

令牌使用安全存储，业务 SQLite 和私有媒体不等于端到端加密。运维备份必须同时包含数据库与媒体，按 [server/README.md](server/README.md) 停服务备份、校验和恢复到新目录；这与已移除的用户 JSON 导出无关。不得以清库解决联调问题。
