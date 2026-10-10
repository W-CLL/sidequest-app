# 支线 API：文字内测版

这是可自行部署的后端源代码，不代表已经上线。采用 Node.js 24 内置 HTTP、SQLite 和加密模块，没有 npm 运行依赖。连接同一个持久化数据库的客户端共享唯一昵称与私密账号数据；仅在手机本地运行的演示模式不具备跨设备昵称唯一性。

## 本地启动

先安装 Node.js 24，在本目录运行：

```sh
node --test
node server.mjs
```

默认监听 `127.0.0.1:8787`，数据库为相对于工作目录的 `data/sidequest.sqlite`。健康检查：`GET http://127.0.0.1:8787/api/health`。测试使用临时数据库，完成后清理，不读取实际账号库。

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `HOST` | `127.0.0.1` | 不默认向公网或局域网暴露 |
| `PORT` | `8787` | 监听端口 |
| `DATABASE_PATH` | `./data/sidequest.sqlite` | 持久化 SQLite 路径，建议部署时使用绝对路径 |
| `ALLOWED_ORIGINS` | 空 | 浏览器来源白名单，逗号分隔，例如 `https://preview.example.com`；不使用通配符 |

正式远程访问必须放在 HTTPS 反向代理后，客户端构建时设 `--dart-define=API_BASE_URL=https://api.your-domain.example`，不要在 URL 后加 `/api`。原生手机应用不发送浏览器 Origin，浏览器联调则必须显式配置精确来源。

本地 Android 模拟器访问宿主机通常用 `http://10.0.2.2:8787`。实体 Android 通过 USB 连到开发机时，可使用 `adb reverse tcp:8787 tcp:8787` 再连接 `http://127.0.0.1:8787`。这两种明文地址仅用于开发测试，不应在不可信网络使用；客户端也需要仅开发配置允许明文。不要使用真实敏感记录测试明文连接。

## 试运行部署

1. 使用带持久磁盘的单个 Node.js 24 服务进程，为该服务分配低权限系统账号。设置数据库目录所有者及访问权限；Windows 需另外配置 NTFS ACL。
2. 将数据库及其目录排除在 Git、公共文件服务器和日志采集之外。不要把容器临时文件系统当成持久盘。
3. 让 HTTPS 反向代理将请求转发到环回地址 `127.0.0.1:8787`，限制请求体不超过 16 KiB，配置连接/请求超时，并额外提供按真实客户端 IP 的速率限制。代理访问日志不得记录请求体、Authorization 或查询中的凭据。
4. 配置 HTTPS 域名后，重新打包带 `API_BASE_URL` 的 Android 客户端。先验证 `/api/health`，然后用两个账号验证登录、私密记录隔离和退出失效。
5. 对数据库制定加密备份、恢复演练及备份到期删除政策。恢复旧备份可能恢复先前已经删除的记录；不得承诺立即擦除所有备份。

可选 Caddy 示例（将域名替换为实际域名）：

```caddyfile
api.your-domain.example {
    request_body {
        max_size 16KB
    }
    reverse_proxy 127.0.0.1:8787
}
```

示例只展示 HTTPS 转发，不是完整的生产加固配置；Caddy 需要实际域名/DNS 和可用的 80/443 端口才能自动获取证书。服务本身不会申请证书、开通主机或部署到 GitHub。GitHub Actions 可运行测试，但不等于长期托管服务。

## 已实现的账号与任务规则

- 浏览推荐不要求登录，领取/换题/保存/完成必须先登录。账号使用稳定 UUID；昵称不是数据库主键，也不能代替密码认证。
- 昵称 NFKC 标准化并去除首尾空格，2–20 个 Unicode 字母/数字、下划线或短横线；比较时转小写。因此 `Ａlice`、`Alice`、`alice` 视为同一昵称。SQLite UNIQUE 约束最终保证并发唯一性。这不是完整的 Unicode 视觉相似字符识别。
- 密码 8–128 个 Unicode 字符；服务端使用随机盐与 scrypt 派生，不保存明文密码。会话令牌为 32 字节随机值，只保存 SHA-256 摘要，7 天绝对过期；退出立即撤销当前会话。
- 不收手机号/邮箱，不提供密码找回。忘记密码且没有可用登录方式将无法恢复该账号；测试前务必告知参与者。首版没有改昵称或修改密码接口。
- 每个账号同时最多一个支线。每天只推荐一个入口，完成后可主动选下一条；没有连续签到或完成惩罚。
- 换题按 **Asia/Shanghai 自然日** 每账号一次，不是每个任务一次；该解释是本次初版的实施约定。可以在领取前更换推荐，或者在领取后更换当前任务。
- 确认换题后清空旧任务草稿，避免将旧记录误交给新任务；停止任务仍保留草稿。只有当前已领取任务时才允许保存或修改草稿。
- 安全停止不扣除额外额度、也不发新题；它清除领取状态但保留当前推荐及草稿。重新领取仍是该推荐。更换身份/偏好不会刷新推荐或换题次数。
- 完成会生成私密日记，清除草稿，设置 `canRequestNext=true`；之后必须主动请求 `next` 才能领取下一题。删除日记不影响进度，不能借此重置规则。
- 日切保留未完成任务和草稿；前一天已完成且尚未选下一条时，新的自然日自动将推荐前进一条。换题记录保留日期，与当天日期比较。
- 首版从 `green` 起始，按固定目录顺序轮转；身份/偏好可保存，个性化任务排序未实现，不声称是智能推荐。

## 内容与隐私边界

本次是**纯文字 alpha**：草稿允许 0–300 个 Unicode 码点，完成记录要求 1–300 个码点且不能全空白。不存在上传端点；多余的 `media` 等字段会被拒绝。图片、音频、视频格式/大小校验、元数据清理、对象存储、通知推送和分享卡片服务都未在本后端实现。原设计中的媒体限额不能解释为已支持上传。

记录默认只对账号本身可见，没有公共列表或公开搜索接口。导出不含密码散列、盐或令牌。删除账号需要再次验证密码，并从活跃数据库逻辑删除用户、任务、日记和所有会话。SQLite WAL、存储介质或外部备份中可能仍有历史残留；本服务不承诺取证级安全擦除。

服务不记录请求体、密码或令牌。数据库当前不是应用层加密，也不是端到端加密；主机管理员和有数据库权限的人能够读取日记。部署者需使用磁盘加密、最小权限及适当的隐私告知。不可用于收集高敏感数据或直接作为生产安全合规承诺。

认证限制默认同一连接来源 IP 或昵称每 15 分钟最多 30 次，密码计算最多并行 4 个，JSON 最大 16 KiB。内存限流会随重启清空，不在多实例间共享；服务不信任 `X-Forwarded-For`。在反向代理后，连接来源通常都是代理 IP，因此这 30 次是代理下合计额度；扩大内测前应加入受信代理配置与共享限流，而不是假装已有生产级防滥用。

## API 契约

所有 POST 请求必须 `Content-Type: application/json`。私有端点使用 `Authorization: Bearer <token>`，不要放进 URL。错误为 `{"error":"中文提示"}`。`register/login` 返回 `{"token":"...","state":{...}}`，其他状态操作返回 `{"state":{...}}`。

| 方法与路径 | 请求体/说明 |
| --- | --- |
| `GET /api/health` | 不含用户数据的存活检查 |
| `GET /api/state` | 无 token 返回访客；无效 token 返回 401，不降级为访客 |
| `GET /api/export` | 要求登录，返回 `schemaVersion/exportedAt/timezone/state` |
| `POST /api/register` | `nickname,password,role,preferences` |
| `POST /api/login` | `nickname,password` |
| `POST /api/logout` | `{}`；撤销当前令牌 |
| `POST /api/preferences` | `role,preferences` |
| `POST /api/claim` | `{}`；领取推荐，有当前任务时幂等 |
| `POST /api/replace` | `{}`；每天一次，清空旧草稿 |
| `POST /api/stop` | `{}`；随时停止，保留草稿 |
| `POST /api/draft` | `text` |
| `POST /api/complete` | `text`；原子完成，重复并发请求不会写两条 |
| `POST /api/next` | `{}`；只有完成后才允许 |
| `POST /api/delete-entry` | `id`；仅能删除自己的记录 |
| `POST /api/delete-account` | `password`；删除账号及所有会话 |

`role` 允许 `student/employee/freelancer/leader/caregiver/retired/transition/other`；`preferences` 最多三个、不重复，可选值为 `安静独处、熟人同行、观察细节、动手创作、尝试新鲜、熟悉安心`。

状态结构：

```json
{
  "profile": {"id": "immutable-uuid", "nickname": "玩家", "role": "student", "preferences": []},
  "activeQuestId": null,
  "recommendedQuestId": "green",
  "entries": [{"id": "entry-uuid", "questId": "green", "questTitle": "三种绿色", "text": "我的发现", "createdAt": "2026-10-10T06:00:00.000Z"}],
  "replacedOn": null,
  "draft": "",
  "day": "2026-10-10",
  "canRequestNext": true
}
```

访客 `profile=null`，没有个人草稿、换题记录或日记。`entries` 按旧到新排序，同一时间的记录按插入顺序排列；客户端可以倒序展示。状态响应目前一次返回全部日记，尚无分页、离线冲突合并或跨设备实时推送，适用于小规模验证。
