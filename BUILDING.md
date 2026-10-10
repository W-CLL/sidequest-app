# 支线 Android 内测版：构建与安装

本项目使用 Flutter 同一套业务和界面代码，首轮交付目标是 Android 调试 APK。`ios/` 保留，但本轮未进行 iOS 编译或真机验证。当前没有创建远程 Git 仓库，没有执行 GitHub Actions，也没有配置云端部署。

## 本轮实测结果（2026-10-10）

本机已成功执行 `flutter build apk --debug --split-per-abi`，生成 ARM64、ARMv7 和 x86_64 三份 APK。首次完整构建用时约 94 秒；最后更换图标后的增量构建用时约 6 秒。最终 APK 时间为 12:25:19，晚于所有 `lib/*.dart` 文件最后修改时间（最新 12:19:08）与图标资源。

Android 五档 mipmap 和 iOS 全部 AppIcon 已替换为森林绿底、浅黄叶子的本地程序绘制图标，非默认 Flutter 图标。最终交付 APK 已重新校验签名和权限，SHA-256 文件已更新。构建完成后已停止本次 Gradle daemon。

- 三包均通过 Android `apksigner verify --verbose`（APK v2 签名），显示名“支线”，包名 `app.sidequest.sidequest`，版本 `0.1.0`，最低 Android 7.0 / API 24。
- `aapt dump badging` 核对权限只有 INTERNET 和应用内部的 signature 级 receiver 权限，无 GPS、相机、麦克风、相册或通知权限。
- Android SDK Platform 34 / 35 被插件构建依赖自动安装，使用环境已有的已接受许可证；未运行接受许可证的命令，未升级 NDK 或安装模拟器。
- `share_plus` 11.1.0 有未来 Flutter 内置 Kotlin 兼容性警告，不影响本轮成功构建；升级 Flutter 前应重新验证该依赖。
- 没有连接 Android 手机，故尚未做安装启动、软键盘、系统分享面板的真机验证。
- GitHub workflow 仅已写入，尚未在 GitHub 执行；iOS 尚未构建。

交付目录中提供 `sidequest-android-v0.1.0-arm64.apk`（多数较新手机）与 `sidequest-android-v0.1.0-armv7.apk`（部分旧款 32 位手机），以及 `sidequest-apk-sha256.txt`。测试包采用单机模式，没有编译公共 API 地址。

## 版本与前提

- Flutter **3.47.0 stable**、Dart **3.13.0**。
- JDK **21**；Android Gradle Plugin **9.1.0**；Gradle **9.3.1**。wrapper 使用官方 `bin` 分发包并固定 SHA-256，避免下载无须使用的完整文档包。
- Android SDK Platform **36**、Build Tools **36.0.0**、NDK **28.2.13676358**（沿用 Flutter 模板默认版本）。
- 当前 Flutter 默认最低 Android API **24**（Android 7.0）。
- 首次构建需要访问 pub.dev、Google Maven、Maven Central、Gradle 和 Flutter 下载源。网络失败不能视作 APK 已完成。
- 如 SDK 报告许可证未接受，需要环境所有者自行阅读并同意相关条款；本项目脚本不会在本机代为接受。

若官方 Gradle / Google Maven 下载超时，而系统浏览器能正常访问，可检查 Java 是否遗漏了现有代理配置。仅给当前构建进程配置经过确认的代理，不修改系统或用户级 Gradle 配置，也不要换用来源不明的镜像。本轮本地构建使用了机器已经配置的回环代理，并验证 Gradle 包的 SHA-256；代理地址不写入项目或 GitHub workflow。

## 本机构建

在本目录运行：

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug --split-per-abi
```

默认未设置 `API_BASE_URL`，用于本机数据的初步体验。单机模式的昵称唯一性不等于跨设备全局唯一，也不是已上线的云账号服务。清除应用数据、卸载或更换设备可能导致本地账号及记录丢失；不要用于保存不可替代的私人资料。

产物位于 `build/app/outputs/flutter-apk/`：

- `app-arm64-v8a-debug.apk`：多数较新的实体 Android 手机。
- `app-armeabi-v7a-debug.apk`：部分较老的 32 位 ARM 手机。
- `app-x86_64-debug.apk`：对应架构的模拟器等设备。

安装到已连接并允许 USB 调试的测试手机：

```powershell
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk
```

也可以将匹配设备架构的 APK 传到手机，授权对应文件管理器“安装未知应用”后安装。仅向受信任的内测者分发。

Android 安装包仍必须签名，但 **debug 签名由工具自动生成**，本轮不需要用户准备发布证书。调试包可调试，不是生产发行包。不同电脑或 GitHub 全新 runner 生成的 debug key 可能不同，旧版本可能无法直接覆盖安装；不要把签名 key 上传到公开仓库。遇到签名冲突时，先保护需要保留的资料，再决定是否卸载旧包。

## 可选 API 接入

仅在服务已由你部署且可通过 HTTPS 访问时设置，例如：

```powershell
flutter build apk --debug --split-per-abi --dart-define=API_BASE_URL=https://your-api.example.com
```

该地址会编译进客户端，**不能包含密码、token 或其他秘密**。配置 URL 本身不会部署后端、创建数据库或开通存储。客户端和服务端仍须分别测试。生产/分发默认禁止明文 HTTP；iOS 保持系统默认 HTTPS 限制。

仅限 USB 本机联调时，可将后端绑定到电脑的 `127.0.0.1:8080` 并执行：

```powershell
adb reverse tcp:8080 tcp:8080
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8080
```

Android debug 资源仅为 `127.0.0.1` 与 `localhost` 放行 HTTP；不放行局域网任意地址，不把开发后端绑定到 `0.0.0.0`。结束后可运行 `adb reverse --remove tcp:8080`。应用自身的 URL 校验如禁止该调试入口，应以该校验为准，不要为联调放宽发布版策略。

## GitHub 手动构建

提供的 `.github/workflows/android-alpha.yml` 假设**此目录内容就是 Git 仓库根目录**。如果把它放在大型仓库的子目录，需要同步调整 workflow 的执行目录及产物路径。

1. 在你授权的新建或现有仓库中放入本项目；本轮尚未执行此步骤。
2. 打开 GitHub 的 Actions → Android alpha APK → Run workflow。
3. `api_base_url` 留空生成单机 alpha；填写无凭据的公开 HTTPS URL 才编译 API 地址。
4. 流程依次安装固定版本 Flutter/JDK、解析依赖、静态检查、运行测试，再构建各架构的 debug APK。
5. 成功后下载 `sidequest-android-alpha-<运行号>` artifact，解压并选择合适 APK。SHA256SUMS 文件用于核对下载文件，非发行证书。产物保留 14 天。

流程只申请仓库读取权限，只能手动启动，不自动发布 Release，不需要提供签名秘密，不创建服务器。API 输入通过环境变量传递并校验，避免直接插入 shell 脚本。HTTPS URL 校验不能替代服务端鉴权或安全审计。

## 原生权限与隐私边界

- Android / iOS 应用显示名为“支线”。
- 本轮文字体验不请求定位、摄像头、麦克风、相册权限，不追踪轨迹。
- Android 禁用自动备份，并排除云备份及设备迁移中的应用文件、数据库和偏好数据。设备厂商及被 root 设备的行为不属于应用可保证的范围。
- 发布配置禁止 HTTP；只有 Android debug 的明确回环地址允许本机联调。
- Android release 签名未配置，避免误把 debug key 当作生产发布证书。
- 图片、音频、视频、定时通知需后续分别实现并测试，不能把 UI 中的计划/规则当成已可用能力。

## iOS 后续

`ios/` 与 Android 共用 Flutter 源码，但平台权限、系统选择器、键盘和分享面板会有差异。本轮 Windows 环境无法完成 iOS 模拟器或真机验证。未来需 macOS/Xcode 构建；真机安装仍需有效签名/开发团队配置，未上架不代表可以跳过签名。此仓库暂不包含 iOS 签名或发布 workflow。
