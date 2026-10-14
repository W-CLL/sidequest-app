# 支线服务端 · 云服务器部署指南

目标：把主服务部署到云服务器（Ubuntu 22.04+ 示例），配好域名的 HTTPS；
手机安装 APK 后直接可用。APK 的更新走下载页或后台「版本分发」。

> 背景：客户端只接受 `https://` 地址（或本机回环），所以域名 + Caddy 自动
> HTTPS 是最省心的方案。没有域名时，也可以先用 Cloudflare 临时隧道
> （`cloudflared tunnel --url http://127.0.0.1:8787`）拿到一个 https 地址。

## 0. 前置

- 云服务器（1C1G 起即可）+ SSH 登录信息
- 一个域名，A 记录解析到服务器公网 IP
- 安全组 / 防火墙放行 22、80、443（`ufw allow 80,443/tcp` 如启用 ufw）

## 1. SSH 连接

```bash
ssh root@<服务器IP>
```

## 2. 安装 Node 24 与 ffmpeg

```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt install -y nodejs ffmpeg
node -v                    # 应为 v24.x
ffmpeg -version | head -1
```

## 3. 上传代码（在本地 Windows 执行）

```bash
scp -r D:/code_file/pro_python/sidequest-app/server root@<服务器IP>:/opt/sidequest/
```

服务器上清理本机文件、建数据目录：

```bash
rm -rf /opt/sidequest/server/admin/.venv /opt/sidequest/server/admin/admin.sqlite
mkdir -p /opt/sidequest/data/apk
```

## 4. 试运行

```bash
cd /opt/sidequest/server
DATABASE_PATH=/opt/sidequest/data/sidequest-v2.sqlite \
MEDIA_DIRECTORY=/opt/sidequest/data/media \
APK_DIRECTORY=/opt/sidequest/data/apk \
node server.mjs
```

另开窗口 `curl http://127.0.0.1:8787/api/health` 应返回 JSON；Ctrl+C 停掉，改用 systemd。

## 5. 常驻（systemd，开机自启 + 崩溃自动重启）

```bash
cat > /etc/systemd/system/sidequest.service <<'EOF'
[Unit]
Description=Sidequest API
After=network.target

[Service]
WorkingDirectory=/opt/sidequest/server
Environment=DATABASE_PATH=/opt/sidequest/data/sidequest-v2.sqlite
Environment=MEDIA_DIRECTORY=/opt/sidequest/data/media
Environment=APK_DIRECTORY=/opt/sidequest/data/apk
ExecStart=/usr/bin/node server.mjs
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now sidequest
systemctl status sidequest --no-pager
```

## 6. HTTPS（Caddy 自动证书）

```bash
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy
```

`/etc/caddy/Caddyfile`：

```
zx.你的域名.com {
    reverse_proxy 127.0.0.1:8787
}
```

```bash
systemctl reload caddy
```

浏览器打开 `https://zx.你的域名.com/download` 验证（首次签发证书约几秒）。

## 7. 构建并分发 APK

本地：

```bash
flutter build apk --dart-define=API_BASE_URL=https://zx.你的域名.com
scp build/app/outputs/flutter-apk/app-release.apk root@<服务器IP>:/opt/sidequest/data/apk/sidequest-0.2.0.apk
```

手机浏览器打开 `https://zx.你的域名.com/download` → 下载 → 安装 → 直接可用。

## 8. 后台（可选：传 APK / 看数据）

```bash
apt install -y python3 python3-venv python3-pip
# server/admin 已随第 3 步上传；如果只想传 APK，也可以不做本节，直接用 scp
cd /opt/sidequest/server/admin
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
# 注意：必须显式 --database=django（否则 plain migrate 会往业务库写"跳过执行但已记录"
# 的假账，后台库仍然没有表）
.venv/bin/python manage.py migrate --database=django
.venv/bin/python manage.py createsuperuser --database=django
SIDEQUEST_DB=/opt/sidequest/data/sidequest-v2.sqlite \
SIDEQUEST_MEDIA_DIR=/opt/sidequest/data/media \
SIDEQUEST_APK_DIR=/opt/sidequest/data/apk \
SIDEQUEST_PUBLIC_BASE_URL=https://zx.你的域名.com \
.venv/bin/python manage.py runserver 127.0.0.1:8788
```

后台不暴露公网，本地用 SSH 隧道访问（最安全）：

```bash
ssh -L 8788:127.0.0.1:8788 root@<服务器IP>
# 然后浏览器打开 http://127.0.0.1:8788/admin/
```

「分发 → 版本分发」页面上传 APK 即可——上传后下载链接自动指向新包。
长期常驻可用 systemd/tmux 包一层上面那条 runserver 命令。

## 9. 以后更新

1. 本地改代码 → 重新 `scp` 覆盖 `/opt/sidequest/server`（排除 `.venv`）
2. `systemctl restart sidequest`
3. 重新构建 APK → 上传到 `/opt/sidequest/data/apk/`（scp 或后台页面）
4. 用户打开下载页更新；已同步的记录不受影响——提醒用户更新前先等同步完成

## 备份提示

备份 `/opt/sidequest/data/`（数据库 + 媒体 + APK 三样）。
`server/backup.mjs` 可生成带校验清单的一致性备份包。

## 附录：CentOS 8 + 宝塔 环境实测（2026-10-12 已在线）

与上文 Ubuntu/Caddy 路径的对应关系（真实部署环境：腾讯云 CentOS 8.5 + 宝塔 + nginx）：

- **Node**：系统已有 `/usr/bin/node` v24；ffmpeg 用静态版：johnvansickle
  `ffmpeg-release-amd64-static.tar.xz`（慢时兜底 ghproxy 的 BtbN 构建）→ 安装到
  `/usr/local/bin`；systemd 单元显式给 `FFMPEG_PATH` / `FFPROBE_PATH`。
- **Python 3.12（Django 6 要求）**：CentOS 8 自带 3.6 不够——用 NJU 镜像的
  python-build-standalone（astral-sh 仓库）：
  `https://mirror.nju.edu.cn/github-release/astral-sh/python-build-standalone/20261009/cpython-3.12.15+20261009-x86_64-unknown-linux-gnu-install_only.tar.gz`
  → 解压到 `/usr/local/python312`，用它建 admin 的 venv。
- **后台初始化必须 `--database=django`**：`migrate` 与 `createsuperuser` 都是。plain
  `migrate` 会把迁移"记录为已应用但不建表"写进业务库（Django 对被路由器跳过的库的行为，
  打印 Applying OK 却不执行），后台库仍然为空。
- **HTTPS 用宝塔 nginx + acme.sh**（不用 Caddy）：acme.sh 从 gitee 镜像安装（官方源走
  raw.githubusercontent 不通）；`--webroot` 签发到 `/www/server/panel/vhost/cert/<名>/`
  （安装 cert 时 `--reloadcmd "nginx -s reload"`）。
- **⚠️ 宝塔的 `/www/server/panel/vhost/` 是 `700 root`**：nginx 以 www 用户运行读不到
  里面的文件——basic auth 的 htpasswd 必须放 www 可读的位置（实测放
  `/www/sidequest-data/sidequest-admin.htpasswd`），否则**带凭据的请求返回 500**、
  不带凭据的返回 401（极难排查）。
- 两个 systemd 服务：`sidequest`（8787 主服务）与 `sidequest-admin`（8788 云后台，
  经 nginx 子域 + basic auth + Django 登录双保险反代）。
- **release 包默认未签名**（`android/app/build.gradle.kts` 刻意不给 release 配签名，
  防止静默复用开发密钥）：`flutter build apk --release` 产出的 `app-release.apk` 直接装
  会报 `INSTALL_PARSE_FAILED_NO_CERTIFICATES`。分发到 `/download` 前必须先补签（用调试
  密钥，与既有测试包签名一致、可平滑覆盖安装）：
  ```bash
  BT=$(ls "$LOCALAPPDATA/Android/Sdk/build-tools/" | sort -V | tail -1)
  "$LOCALAPPDATA/Android/Sdk/build-tools/$BT/apksigner.bat" sign \
    --ks "C:/Users/A/.android/debug.keystore" --ks-pass pass:android \
    --key-pass pass:android --ks-key-alias androiddebugkey \
    --out app-release-signed.apk app-release.apk
  ```
  Windows 注意：keystore 路径必须写成 `C:/...`（MSYS 的 `/c/...` 会被转坏）。
- `/download/latest` 与 `/download`、`/`、`/privacy`、`/terms` 均接受 **GET 与 HEAD**
  （下载管理器/聊天软件点链接常先 HEAD 探测；早期版本 HEAD 会落到协议校验吃到 426）。
- **OSS 分发加速（2026-10-13 起）**：APK 自动同步到阿里云 OSS（复用桌搭子的 bucket
  `cllllc`，前缀 `sidequest/`），`/download/latest` 302 到 `oss-download.desktoppet.online`
  的签名直链（15 分钟有效）。OSS 未配置/上传失败/探测超时都会无感回退服务器带宽，
  老链接始终有效。配置：`/root/sidequest-oss.env`（systemd `EnvironmentFile=` 注入，
  键取自 `/root/deskpet-oss-private.json`）；后台「版本分发」上传成功后自动调
  `POST http://127.0.0.1:8787/internal/oss-warm` 预热（nginx 已把该路径对外 404）。
  ⚠️ 签名要点：URL 签名的 CanonicalizedResource 必须写 `/{bucket}/{key}`，即使通过
  自定义域名访问也一样（实测对刀 ali-oss SDK；少写 bucket 会 403）。
- **下载统计（2026-10-13 起）**：主服务把 `/download` 访问（GET）与 `/download/latest`
  下载请求（GET，HEAD 探测不计）写 `<数据目录>/downloads.jsonl`（4 MiB 上限；IP 取自
  `X-Real-IP`——经 nginx 时 socket 都是 127.0.0.1；含 source=wechat/qq/browser、
  referer、via=oss|server）。后台「分发 → 下载统计」聚合展示：今日/累计指标、按天 14 天、
  来源与通道、最近事件（50 条/页）。只统计下载链接的公开访问，App 不采集任何行为数据。

## 附录：Web 版（iOS/浏览器）部署记录（2026-10-14 已上线）

网页版由同一仓库构建为 Flutter Web 客户端，计划托管在 `https://zx.desktoppet.online/app`
（同源、无 CORS、复用现有证书）。上线时按以下步骤执行：

1. **本地构建**（仓库根目录）：
   ```bash
   flutter build web --release --base-href /app/
   ```
   产物在 `build/web/`。

2. **上传静态产物**，例如 `/www/sidequest-web/current/`（先传新目录再切软链，保留上一版便于回滚）。

3. **nginx 增加一个 location**（站点 `zx.desktoppet.online` 的配置里）：
   ```nginx
   location = /app { return 301 /app/; }
   location /app/ {
       alias /www/sidequest-web/current/;
       try_files $uri $uri/ /app/index.html;   # 回退必须写站点绝对路径，否则会落到 alias 之外
   }
   ```

4. **允许网页版来源**：主服务 systemd 单元加
   `Environment=ALLOWED_ORIGINS=https://zx.desktoppet.online`（浏览器 POST/PUT 会带 Origin 头，
   不在列表会 403；安卓 App 请求不带 Origin，不受影响）。并确认服务端代码已包含 Cookie 会话支持。

5. **重启顺序（重要）**：先 `systemctl restart sidequest`（主服务启动时会给旧库补上
   `sessions.client` 列），再 `systemctl restart sidequest-admin`（后台「登录会话」需要读这列）。

6. 验证：浏览器打开 `https://zx.desktoppet.online/app` → 注册/登录 → 记录一条（含图片）；
   后台「登录会话」应显示来源「网页 0.2.0+3」。

本地联调方式见根目录 `BUILDING.md` 的「Web 版」一节（`scripts/serve-web.mjs` 同源代理）。

**已执行（2026-10-14）**：静态产物在 `/www/sidequest-web/current/`（构建：`flutter build web --release --base-href /app/ --no-web-resources-cdn --output build/web-app`）；nginx 站点配置备份 `/root/zx.conf.bak-20261014`、`/root/zx.conf.bak-20261014b`；主服务单元备份 `/root/sidequest.service.bak-20261014`；全站 gzip 类型增加 `application/wasm`（canvaskit 首载 7.3MB，压缩后传输约三分之一）。生产验证：`/app/` 200、后台冒烟 79/79、无头浏览器实测启动零报错、`GET /api/state` 200。旧版静态产物备份在 `/www/sidequest-web/current.prev-20261014/`（回滚用）。

### 白屏根因修复（2026-10-14 晚）

Flutter Web 发布构建默认从 **gstatic.com（Google CDN）** 拉取 CanvasKit 图形引擎与缺字回退字体；国内网络不可达/极慢时表现为**整页白屏**（引擎起不来），即使引擎起来、中文也依赖 fonts.gstatic.com。修复三件事：

1. **引擎本地化**：构建加 `--no-web-resources-cdn`（buildConfig 中 `useLocalCanvasKit: true`，canvaskit 走 `/app/canvaskit/`）。
2. **回退字体镜像**：自定义 `web/flutter_bootstrap.js`，`initializeEngine({ fontFallbackBaseUrl: "https://zx.desktoppet.online/app/webfonts/s/" })`；服务器镜像 **555 个回退字体文件**（6 家族：简中 97 / 日 120 / 韩 120 / 繁中 101 / 港 105 / emoji 12，约 15MB）于 `/www/sidequest-web/webfonts/`；nginx 增加 `location /app/webfonts/`（alias + `Access-Control-Allow-Origin: *`，便于本地联调跨源取字体）。文件清单：`server/web-fonts-mirror-list.txt`（由构建产物 `main.dart.js` 中 `A.c("Noto …", "family/vNN/<hash>.<n>.woff2")` 正则提取；Flutter 升级后重新提取并增量下载）。
3. **启动期重绘驱动**：引擎在回退字体下载完成后不会主动重绘（页面静止时中文会停留在方块字，直到用户第一次触摸/移动）→ `lib/main.dart` 启动后 18 秒内每 300ms `markNeedsPaint + scheduleFrame` 一次（`kIsWeb` 门控，其它平台零影响）。

验证方式（真实 WebKit 引擎 + 屏蔽 gstatic + 零输入）：Playwright `webkit` 打开 `/app/`，`route` 阻断 `gstatic.com|googleapis.com`，截图确认中文正常、0 请求失败。另修复「添加到主屏幕」提示条在非 iOS 设备误显示（`#add-to-home[hidden] { display: none; }`——原 CSS `display:flex` 覆盖了 `hidden` 属性）。

⚠️ 验收注意：zx 站点有爬虫守卫（`sidequest-bot-guard.conf`，挡 curl/wget/python 等脚本 UA）——**手工 curl 探测必须带浏览器 UA**（例如 `-A "Mozilla/5.0 ..."`），否则一律 403；微信/QQ/浏览器/App 不受影响。

**2026-10-14 晚增量（启动体验与品牌）**：① 品牌图标：把安卓端图标（墨绿底 + 嫩芽）移植为 Web 全套（`web/icons/*`、`web/favicon.png`；用 Pillow 对平色图形做掩膜放大生成，边缘干净）；② 启动画面：`index.html` 静态 splash（图标 + 支线 + 正在准备…），由 `flutter-first-frame` 事件移除，30 秒兜底（慢网络下不至于提前露出白屏）；③ 资源预加载：仅 `main.dart.js`（as=script）与 `canvaskit.js`（as=script + crossorigin，按 UA 选引擎变体）——**wasm 不要预加载**：与引擎 `fetch()` 的模式不匹配，实测 WebKit 会整份重复下载（2 × 2.9MB，反而变慢）；④ 「添加到主屏幕」提示改为可关闭弹窗（右上角 ×，`localStorage: sq-hint-add-home` 记忆，首帧后弹出，仅 iPhone/iPad Safari）。
