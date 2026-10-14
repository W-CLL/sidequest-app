# 支线 iOS（Web 版）方案 · 定稿

- 状态：**已定稿，未实施**（2026-10-12）。本文档只确定方案；尚未编写任何代码。
- 背景：iOS 真机安装必须经过签名（不同于 Android 可自签名分发）。Web 版 + Safari「添加到主屏幕」可绕过签名、开发者账号与 App Store 审核，是 iPhone 用户使用支线的最轻路径。
- 方向确认（用户拍板）：去掉本地存储、记录直接经接口保存、登录会话保存在浏览器端。

## 一、方案总览

Web 版是**在线优先**的轻量客户端：不设本地数据库，所有数据直接读写服务器；登录会话保存在浏览器（Cookie）。交互与数据同 Android 版共用同一账号体系。

数据流（全部使用服务端**现有**接口，无新增协议）：

| 环节 | 接口 |
|---|---|
| 注册 / 登录 / 退出 | `POST /api/register` · `POST /api/login` · `POST /api/logout` |
| 选择媒体 | `POST /api/uploads`（占位）→ `PUT /api/uploads/<id>/content` |
| 草稿自动保存 | `POST /api/draft`（服务端已有草稿存储；刷新、换设备可续写） |
| 提交记录 | `POST /api/complete`（`clientRecordId` 幂等去重） |
| 探索册 | `GET /api/entries`（分页）· `GET /api/entries/<id>` · `POST /api/update-entry` · `POST /api/delete-entry` |
| 活动状态 | `GET /api/state` · `POST /api/claim / next / replace` |

明确不使用：`/api/sync`、`/api/sync-status` 与离线队列协议——Web 版没有离线队列。

## 二、五个已定稿的决定（按建议默认采纳）

1. **登录会话承载：HttpOnly Cookie**（HttpOnly + Secure + SameSite=Lax，沿用 7 天滑动续期语义）。服务端小改：login/register 响应增加 `Set-Cookie`；`authenticate` 增加一条 cookie 读取路径；logout 清除 cookie。App 的 Bearer 通道不受影响。主屏幕 Web App 与 Safari 共享登录态；清除浏览器数据会掉登录（正常现象）。
2. **草稿：直接使用服务端已有 `/api/draft`**，不引入任何本地存储。断网时输入只存在于页面内存：不刷新不丢；刷新/关页面会丢，关闭前给出提示。不设本地"保险丝"。
3. **v1 媒体范围：文字 + 图片**；视频、语音留到 v2（服务端媒体白名单已覆盖浏览器常见格式 webm / mp4 / m4a，v2 适配成本低）。
4. **客户端形态：先验证 Flutter Web 复用现有界面**（"无本地存储 + Cookie 会话"之后，sqflite / flutter_secure_storage / workmanager 三大障碍全部消失）。验证重点：iOS Safari 的中文输入体验、首屏加载、滚动与键盘行为；不达标则退回"轻量独立前端"。
5. **部署位置：`zx.desktoppet.online/app` 同源路径**（无 CORS、无新证书；入口页引导「添加到主屏幕」）。

## 三、服务端改动清单（很小）

1. Cookie 会话支持（见决定 1）；
2. nginx 增加静态 Web 客户端托管（一个 location）；
3. 其余接口零改动。

## 四、产品边界（实施时必须遵守）

- 明确"需联网使用"：不承诺后台同步、自动上传（iOS Web 平台本身不支持 Background Sync）。
- 提交失败：页内保留内容 + 重试按钮；关闭页面时若草稿未保存给出提示。
- 不采集任何行为数据（沿用 Android 版红线）；所有用户可见文案遵守现有统一文案层规范。
- 探索册不再有"本机待上传 / 服务器已确认"双态；查看与编辑直接读写服务器。
- Android 版架构保持不变（离线 + 同步仍在），Web 版不替代它。

## 五、验证计划（实施时执行）

1. 用现有工程构建 Web 版并部署到测试路径；
2. **需要一台 iPhone 真机**，Safari 走完整流程：注册/登录 → 记录一条（含图片）→ 探索册查看/编辑 → 「添加到主屏幕」→ 独立窗口打开 → 断网打开应用壳；
3. 重点观察：中文输入法、首屏加载时间、图片上传成功率、会话保持。

## 六、非目标（本方案不做）

- 不做推送通知；不做离线记录；不做视频/语音（v2 再评估）；
- 不替代 App Store 正式上架路线（如未来需要，另行评估）。
