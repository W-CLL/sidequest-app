"""管理后台注册入口：站点配置 + 按业务域拆分的 ModelAdmin 模块。

导入本包即完成全部注册（Django 自动发现 `panel.admin`）；
各模块职责：
- accounts / records / media / sync / runtime：业务库镜像表的只读（个别受限编辑）页面
- quests / quest_drawer / quest_backups：探索任务目录（自定义列表 + 抽屉 + 备份回滚）
"""
from django.contrib import admin

from . import accounts, diagnostics, downloads, media, progress, quests, records, releases, runtime, sync  # noqa: F401  导入即注册

admin.site.site_header = '支线 · 服务端管理后台'
admin.site.site_title = '支线管理'
admin.site.index_title = '账号与数据概览（本地运维工具）'
