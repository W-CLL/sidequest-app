# 支线 0.2.0 界面预览

这些图片由 Flutter 渲染，使用本机中文字体，逻辑尺寸为 390×844，输出为 780×1688。用于界面检查，不是 Android 真机截图；系统键盘、相册、录音权限和系统分享面板没有包含在内。账号、正文、同步状态和附件使用测试数据；图片预览包含真实解码的测试图片，视频和语音不自动播放。

| 文件 | 页面与状态 |
| --- | --- |
| `01-role.png` | 身份选择 |
| `02-preferences.png` | 探索偏好 |
| `03-today.png` | 今日推荐 |
| `04-detail.png` | 活动详情 |
| `05-login.png` | 创建账号 |
| `06-record.png` | 文字记录 |
| `07-profile-guest.png` | 我的：未登录 |
| `08-profile-account.png` | 我的：已登录 |
| `09-today-active.png` | 今日：进行中 |
| `10-today-completed.png` | 今日：已完成 |
| `11-journal.png` | 探索册 |
| `12-entry.png` | 记录详情、编辑与分享入口 |
| `13-version.png` | 集中的版本说明 |
| `14-sign-in.png` | 登录已有账号 |
| `15-record-mixed-media.png` | 图片、视频、语音混合记录 |
| `16-sync-status.png` | 待传与失败状态、重试及本次移动网络上传 |
| `17-share-selection-default.png` | 分享图片选择，默认不勾选 |
| `18-share-text-preview.png` | 独立的纯文字分享预览 |
| `19-share-photo-preview.png` | 用户选择图片后的分享预览 |
| `details/*.png` | 40 条目录活动的详情首屏 |

重新生成：

```text
flutter test test/preview_capture_test.dart --dart-define=CAPTURE_PREVIEWS=true
```

其他系统通过 `SIDEQUEST_PREVIEW_FONT` 配置可用的中文 TTF/TTC 字体。详见根目录 [BUILDING.md](../BUILDING.md)。
