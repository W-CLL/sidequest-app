# 支线 0.1.1 界面预览

这些图片由 Flutter 渲染，使用本机中文字体，逻辑尺寸为 390×844，输出为 780×1688。用于界面验收，不是 Android 真机截图；系统键盘、分享和导出面板没有包含在内。

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
| `12-entry.png` | 记录详情与分享卡 |
| `13-version.png` | 集中的版本说明 |
| `14-sign-in.png` | 登录已有账号 |
| `details/*.png` | 16 条目录活动的详情首屏 |

重新生成：

```text
flutter test test/preview_capture_test.dart --dart-define=CAPTURE_PREVIEWS=true
```

其他系统通过 `SIDEQUEST_PREVIEW_FONT` 配置可用的中文 TTF/TTC 字体。详见根目录 [BUILDING.md](../BUILDING.md)。
