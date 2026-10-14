# 支线 · 服务端管理后台（Django Admin）

本地运维工具：直挂现有 SQLite 业务库，提供账号、记录、媒体、活动进度、同步排查、
探索任务目录与登录会话的查看与（受限）编辑。界面基于 **django-unfold** 现代主题
（侧边栏导航、暗色模式、森林绿主色），首页为数据仪表盘（统计卡片、最近 7 天记录
趋势图、最新记录）。**只监听 127.0.0.1，仅限本机使用，不要对公网开放。**

## 启动

```powershell
cd server\admin
# 首次：已随仓库包含 .venv 与依赖；若需重建：
#   uv venv .venv
#   uv pip install --python .venv\Scripts\python.exe -r requirements.txt
.venv\Scripts\python.exe manage.py runserver 127.0.0.1:8788
```

或双击 `start.cmd`。浏览器打开：<http://127.0.0.1:8788/admin/>

- 默认数据库：项目根目录 `.runtime/realtest/sidequest-v2.sqlite`（可用环境变量 `SIDEQUEST_DB` 覆盖）
- 默认媒体目录：`.runtime/realtest/media`（可用 `SIDEQUEST_MEDIA_DIR` 覆盖）
- 后台自身数据（登录账号、会话、操作日志）存放在 `server/admin/admin.sqlite`，
  与业务库物理隔离；业务库不会被 Django 建表或改表（所有模型 `managed = False`）。

## 页面总览

| 分组 | 页面 | 说明 |
| --- | --- | --- |
| 数据概览 | 仪表盘 | 统计卡片 / 7 天新记录趋势 / 最新记录 |
| 内容 | 探索任务 | 目录列表（搜索、分页、停用/原始徽章）+ 抽屉查看/新增/编辑 + 停用与排序 + 备份与回滚 |
| 内容 | 记录 / 媒体 / 媒体绑定 | 查看、灯箱弹窗、附件内嵌播放；记录仅可改 text |
| 分发 | 版本分发 | 上传 / 删除 APK，显示对外下载链接；主服务 `/download` 自动取最新包 |
| 账号与同步 | 账号 / 活动进度 / 同步分支 | 进度可编辑（修数据用），其余只读 |
| 账号与同步 | 同步回执 / 指令回执 | 同步重放排查（request_hash / result / receipt） |
| 排查工具 | 删除墓碑 / 媒体清理队列 / 登录会话 / 服务端元数据 / 客户端报错 | 全部只读 |

## 探索任务目录（重点）

- 数据单一事实源：`server/catalog.json`；后台写操作统一走
  「备份 → 写盘 → `scripts/generate-catalog.mjs` 校验并重新生成 `lib/quest_catalog.g.dart`，
  失败自动回滚」。
- **停用 / 启用**：暂停一条任务参与推荐。停用的任务仍保留在目录中（历史记录与已激活
  任务照常展示），但不会再被推荐或轮换到；客户端与服务端一致跳过。写入 `enabled: false`
  （启用时移除该键）。**服务端需重启后生效**。
- **排序**：原始 16 条任务的顺序被生成脚本锁定（列表中有「原始」标记）；只可调整其后
  的任务（抽屉「查看」内的 ↑ / ↓）。
- **保存前预览**：新增/编辑在提交前显示字段级差异（旧值 → 新值），确认后才保存。
- **备份与回滚**（列表页「备份与回滚」）：每次目录改动前自动备份到
  `server/admin/catalog-backups/`（保留最近 50 份，已 gitignore，可在备份页查看 /
  下载 / 一键恢复）；恢复同样先备份当前状态、经生成脚本校验，失败自动回滚。
- 目录校验口径（生成脚本为权威）：≥ 40 条、原始 16 条 ID 与顺序保持、每个偏好
  至少 8 条（按启用项计）、字段白名单（`enabled` 为可选布尔字段）。
- 目录改动后：服务端需重启才进入推荐；App 需重建才显示新任务内容。

## 客户端报错（静默上报）

- 客户端遇到网络 / 同步等错误时静默上报（用户无感知，见 `lib/silent_reporter.dart`），
  主服务 `/api/diagnostics` 落盘为 `<业务库目录>/diagnostics.jsonl`（超过 4 MiB 停止写入，
  不占用业务库表结构）。
- 后台「排查工具 → 客户端报错」展示最近 200 条（时间 / 账号 / 位置 / 类型 / 详情 / 来源），
  纯只读、可在无日志时正常打开；可用 `SIDEQUEST_DIAGNOSTICS` 覆盖日志路径。

## 版本分发（APK）

- 「分发 → 版本分发」：上传 / 删除 APK，显示当前包；设置 `SIDEQUEST_PUBLIC_BASE_URL`
  （如 `https://zx.你的域名.com`）后会直接显示可分享的下载链接。
- 目录默认 `<数据目录>/apk`（`SIDEQUEST_APK_DIR` 覆盖）；主服务 `/download` 始终取目录里
  最新（按修改时间）的 `.apk`——上传后无需其它操作。
- 上传校验：仅 `.apk`、≤ 400 MB、zip 魔数（PK 开头）；先写 `.uploading` 临时文件再改名，
  避免半截文件被下载到。
- 云服务器部署步骤见 `server/DEPLOY.md`。

## 自动化检查

```powershell
.venv\Scripts\python.exe manage.py smoke_audit
```

用超管登录态（force_login，不需要密码）遍历全部页面与关键交互路径：各列表 / 详情、
探索任务列表 / 搜索 / 翻页 / 抽屉、备份页与防护路径（非法备份名、GET 写路由重定向）、
媒体缩略图与 Range 请求（206 / 416）、权限收紧（禁增删改）。输出 PASS / FAIL 表，
存在失败时退出码为 1。**全程只读**：校验失败的 POST 不会落盘。

## 代码结构

```
panel/
  models/    业务库镜像模型（全部 managed=False，按业务域拆分：
             accounts / records / media / progress / sync / runtime / catalog）
  catalog/   探索任务目录后端：store（读写与回滚）/ backups（备份文件）/
             forms（抽屉表单）/ constants / errors
  admin/     页面注册，按业务域拆分（导入即注册）：
             accounts / records / media / progress / sync / runtime（镜像表页面）
             quests（列表页）/ quest_drawer（抽屉与停用排序）/ quest_backups（备份页）
             diagnostics（客户端报错页，读 diagnostics.jsonl，不碰数据库）
             releases（版本分发页，上传/删除 APK，不碰数据库）
  management/commands/smoke_audit.py   冒烟审计命令
  static/panel/  quest_drawer.js（抽屉交互）、quest_diff.js（保存前差异预览）、
                 media_modal.js（媒体灯箱）及各样式
  templates/admin/  index.html（仪表盘）、panel/quest_changelist.html、
                    panel/quest_backups.html、panel/diagnostics_changelist.html、
                    panel/releases_changelist.html
```

## 编辑范围（安全口径）

| 模块 | 查看 | 编辑 | 新增/删除 |
| --- | --- | --- | --- |
| 账号 / 登录会话 | ✓ | — | — |
| 探索任务（活动目录） | ✓（搜索、分页、分类/停用统计） | 抽屉内编辑（活动 ID 不可修改） | 新增；删除请用「停用」；备份可整体恢复 |
| 记录 | ✓ | 仅 text | 可删除（本地调试） |
| 媒体 / 媒体绑定 / 清理队列 | ✓ | — | — |
| 同步分支 / 同步回执 / 指令回执 | ✓ | — | — |
| 删除墓碑 / 服务端元数据 / 客户端报错 | ✓ | — | — |
| 版本分发（APK 文件） | ✓ | 上传 / 删除 | — |
| 活动进度 | ✓ | ✓（修数据用） | — |

- 账号与媒体的删除必须走服务端流程（级联 + 媒体清理队列），后台刻意不提供。
- 直接修改记录 text 不会推进 revision、不写哈希；仅本地调试用。
- 数据库含私人内容（记录正文、缩略图），界面截图/快照勿外发。

## 与主服务的关系

后台与 `server.mjs` 可同时运行：SQLite 为 WAL 模式，读并发无碍，写操作偶发
（busy 时自动重试）。强烈建议不要在后台做批量写操作。
