# 支线 API v0.2：账号、离线记录同步与私有媒体

本轮交付完整服务与本地联调，不代表已部署公网。服务使用 Node.js 24 内置 HTTP、SQLite、加密模块；FFmpeg / ffprobe 是必须安装的外部运行依赖。服务端数据库是已保存账号、记录和当前活动的权威来源；手机仅持久化待同步记录、待传文件与冲突草稿。不提供用户 JSON 导入、导出或账号迁移。

## 本地运行

安装 Node.js 24 和含 `libx264`、`mjpeg`、`aac` 编码器的 FFmpeg。启动会检查真实可执行文件，不会绕过校验。默认从 PATH 寻找；也可仅为当前进程指定工具绝对路径。

```powershell
$env:FFMPEG_PATH='C:\path\to\ffmpeg.exe'
$env:FFPROBE_PATH='C:\path\to\ffprobe.exe'
node --test
node server.mjs
```

在 `server/` 目录执行。默认只监听 `127.0.0.1:8787`，采用独立的 `data/sidequest-v2.sqlite` 和 `data/media/`。`GET /api/health` 返回协议版本 2 及媒体工具可用状态。

| 配置 | 默认值 | 含义 |
| --- | --- | --- |
| `HOST` / `PORT` | `127.0.0.1` / `8787` | 本地监听地址 |
| `DATABASE_PATH` | `./data/sidequest-v2.sqlite` | v2 持久化数据库路径 |
| `MEDIA_DIRECTORY` | 数据库目录下的 `media` | 私有持久媒体目录，不是公共静态目录 |
| `FFMPEG_PATH` / `FFPROBE_PATH` | `ffmpeg` / `ffprobe` | 媒体处理工具路径 |
| `ALLOWED_ORIGINS` | 空 | 精确浏览器来源白名单，逗号分隔；原生客户端不需要 Origin |

只初始化空数据库或打开明确标记为 v2 的数据库。检测到旧版或未标记的已有数据库时，在只读检查后拒绝启动，提示使用新路径；不迁移、覆盖或删除旧库。旧客户端的本机数据也不会上传或删除。

同一数据库只允许一个服务进程。旁边的 `.service-lock` 用于阻止重复启动及运行期间备份；正常停止后自动移除，异常退出后仅在确认旧进程不存在时清理这个确切锁文件。

媒体目录的 `.sidequest-media-owner` 与数据库绑定，不能让两个数据库复用同一媒体目录；非空但没有归属标记的目录会被拒绝，现有文件保持不变。清理器仅处理数据库明确登记的附件，不猜测或删除未知子目录。

Android 模拟器和 USB 真机均可使用 `adb reverse tcp:8787 tcp:8787` 后连接 `http://127.0.0.1:8787`。当前 debug 包只为环回地址放行 HTTP，不直接放行模拟器的 `10.0.2.2`。明文地址只用于本地开发测试。客户端需配置 `API_BASE_URL`，不能将 GitHub 仓库当作后端服务。

## 协议与同步

除 health、浏览器 OPTIONS 预检以外，每个请求都必须携带 `X-Sidequest-Protocol: 2`。所有私有请求带 `Authorization: Bearer <token>`，不在 URL 中放令牌。普通 JSON 请求仍限制为 16 KiB；单批同步最多 10 个操作，客户端必须同时满足两项限制。

| 方法与路径 | 请求／结果 |
| --- | --- |
| `GET /api/health` | 版本、时区和协议信息 |
| `POST /api/register` | `nickname,password,role,preferences`，返回 token 与 state |
| `POST /api/login` | `nickname,password`，返回 token 与 state |
| `POST /api/logout` | `{}`，撤销当前会话 |
| `GET /api/state` | 轻量 state；不返回整本记录 |
| `POST /api/preferences` | `role,preferences`，不替换当前活动 |
| `POST /api/replace` | `{}`，上海自然日每天一次，清空旧草稿和附件关联 |
| `POST /api/sync` | `branchId,baseRevision,commands`，返回 state、branchMode、receipts、entries |
| `GET /api/entries?q=&cursor=&limit=20` | 按创建时间／ID 倒序，返回 entries、nextCursor、total |
| `GET /api/entries/:id` | 返回当前账号的单条 entry |
| `POST /api/update-entry` | `id,text,mediaIds,expectedRevision,requestId` |
| `POST /api/delete-entry` | `id,requestId` |
| `POST /api/delete-account` | `password`，验证密码后删除账号及会话 |

`claim/draft/complete/stop/next` 在线便利路径仍可用，正式离线客户端使用 `/sync`。`GET /api/export` 已移除。所有错误返回 `{ "error": "明确提示" }`，旧协议返回 426。

同步命令为 `{commandId,type,payload}`，类型为 `claim {questId}`、`draft {questId,text,mediaIds}`、`complete {clientRecordId,questId,text,mediaIds,createdAt}`、`stop {}`、`next {}`。文字完成记录要求 1–500 个 Unicode 码点，不能全空白；草稿可为空。客户端捕获时间保留为创建时间，后续编辑不改变它。

`baseRevision` 是分支建立时的版本，此分支后续请求不得改变。服务端持久化最近应用版本；遇到任何云端进度变化，整条旧分支永久转为 `records_only`。有效完成记录继续保存，草稿和活动操作不再改变云端进度。本机未完成草稿由客户端独立保留，而不是覆盖云端草稿。

账号＋clientRecordId、账号＋commandId 分别幂等：响应丢失后重试不会重复记录；相同标识对应不同内容返回 409。记录、附件关联、进度变化与命令回执在同一事务中提交。删除保留墓碑，旧完成命令不能复活记录。一个无效命令会回滚整个批次，不产生部分成功。账号之间允许使用相同 clientRecordId，数据仍隔离。

编辑必须联网且通过 expectedRevision 检查；只有提交成功才解除原附件。取消编辑只删除本次新增且尚未绑定的上传，不影响原记录。退出或失效会话不能读取媒体；本机待传队列的保留及明确放弃由客户端负责。

## 私有图片、视频与语音

| 方法与路径 | 用途 |
| --- | --- |
| `POST /api/uploads` | `{kind,byteSize,clientUploadId}` 预约空间，返回 media |
| `PUT /api/uploads/:id/content` | 二进制流式上传，不经过 JSON/Base64 |
| `GET /api/uploads/:id` | 查询 reserved/uploading/processing/ready/failed 及错误 |
| `DELETE /api/uploads/:id` | 取消未绑定上传；属于草稿或记录时拒绝 |
| `GET/HEAD /api/media/:id/content` | 鉴权读取，支持单段 Range |
| `GET/HEAD /api/media/:id/thumbnail` | 同样鉴权的缩略图；音频无缩略图 |

每条记录最多 5 图＋1 段不超过 15 秒视频＋1 段不超过 60 秒语音，可混合但文字必填。源文件分别限制为图片 10 MiB、视频 50 MiB、语音 2 MiB；处理后单图 5 MiB、视频 30 MiB、语音 2 MiB，整条记录附件不超过 45 MiB。账号的已存储与预约处理空间合计不超过 1 GiB，最多 160 个未绑定上传。

预约会计入源文件、最坏处理后文件、应急输出余量及缩略图空间，避免并发先占满磁盘。全局最多 4 个上传、1 个媒体处理；单次探测和处理分别限制为 15 秒与 60 秒。生产公网部署前仍需操作系统进程／磁盘资源限制，不将进程内限额称为生产级沙箱。

仅接受实际可解码的 JPEG、PNG、WebP 图片以及受限媒体容器；不会信任扩展名、客户端 MIME 或文件路径。图片重编码为最长边不超过 1920 的 JPEG；视频重编码为最长边不超过 1280 的 H.264/AAC MP4；录音重编码为单声道 AAC/M4A。去掉元数据、章节和原始文件名，生成私有缩略图。图片／视频源像素不超过 4,000 万且任一边不超过 12,000。转码后再次校验大小、时长和可读取性，不将截断输出标为成功。

文件写入随机媒体 ID 的私有目录，数据库只存关联与元数据。上传完成不等于记录保存；必须等全部附件 ready 后再提交记录。失败处理释放源文件和半成品，保留可重试 reservation。未绑定上传 24 小时过期，已绑定的暂停草稿附件不按年龄删除。

记录／账号删除在数据库事务内写持久化清理任务，事务提交后才删文件；被取消或删除的转码不能重新建立 media 行。重启后重试清理；中断上传转为 failed，同一上传 ID 可重试。媒体 URL 不是公开链接，每次 Range 请求都重新鉴权；已下载到接收者设备的内容无法撤回。

## 运维备份与恢复

这是部署者工具，不是用户 JSON 导入导出。先停止服务，备份数据库与整个私有媒体目录；工具拒绝运行中的数据库、符号链接和已有目标目录。不会删除源文件，也不会覆盖任何现有数据。

```sh
node backup.mjs backup /absolute/data/sidequest-v2.sqlite /absolute/data/media /absolute/backups/new-snapshot
node backup.mjs verify /absolute/backups/new-snapshot
node backup.mjs restore /absolute/backups/new-snapshot /absolute/restored/new-data
```

备份使用 SQLite backup API 得到一致数据库，不遗漏 WAL 中已提交记录；生成文件大小／SHA-256 清单，并验证所有 ready 媒体在备份中存在。恢复仅写全新目录，先验证哈希和数据库完整性，再复制文件；输出新的 DATABASE_PATH 和 MEDIA_DIRECTORY，需显式配置后启动。备份包含账号凭据散列和私密内容，存储介质／备份须加密且限制访问。旧备份可能保留已删除数据，应制定保留与到期销毁政策。

## 验证与安全边界

`node --test` 同时运行 API、SQLite、分支冲突、幂等／墓碑、账户隔离、媒体限额／Range、断流与取消竞争、旧库不改写、备份恢复，以及真实 FFmpeg 转码测试。真实媒体测试不跳过缺失工具；一般 API 单元测试显式注入小型假处理器。所有测试使用确切的临时目录，不读写实际账号库。

账号仍为昵称＋密码：昵称 NFKC 标准化、去首尾空格、转小写唯一；密码采用随机盐和 scrypt，令牌仅存 SHA-256 摘要、7 天过期。未提供密码找回；退出撤销当前会话。数据库和媒体不是端到端加密，具备服务器文件权限的人可读取。文件系统、SQLite WAL 和备份可能存在删除残留，不承诺取证级擦除。

公网部署不在本轮范围。今后部署需 HTTPS、低权限账号、持久磁盘、磁盘加密、反向代理按路径限流及上传大小限制、受信代理真实 IP 策略和合规告知。原 JSON 路径保持 16 KiB，二进制上传单独配置不超过 50 MiB；不得把私有媒体目录映射到公开静态路径。内存认证限流会重启清零，且当前不信任 X-Forwarded-For，不能声称已完成生产级防滥用审计。
