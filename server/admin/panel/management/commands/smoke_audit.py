"""管理后台冒烟审计（只读）。

用法（在 server/admin 下执行）：
    .venv/Scripts/python.exe manage.py smoke_audit

用 Django 测试客户端 + force_login 超管（不需要密码）遍历全部页面与关键交互：
各列表/详情、探索任务列表/搜索/翻页/抽屉、记录抽屉、备份页与防护路径、媒体缩略图与
Range 请求、权限收紧（禁增删改）等。全部检查只读——校验失败的 POST 不会落盘。
存在失败项时退出码为 1，可接进本地检查流程。
"""
from pathlib import Path

from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.test import Client

from panel import catalog
from panel.models import (
    CommandReceipt,
    Entry,
    EntryTombstone,
    LoginSession,
    Media,
    MediaBinding,
    MediaCleanup,
    MutationReceipt,
    QuestState,
    ServerMetadata,
    SyncBranch,
    User as SqUser,
)


class Command(BaseCommand):
    help = '管理后台冒烟审计：遍历全部页面与关键交互路径，输出 PASS/FAIL 表（只读）'

    def handle(self, *args, **options):
        # 测试客户端默认 Host=testserver，仅本次进程内临时放行（不改项目文件）
        if 'testserver' not in settings.ALLOWED_HOSTS:
            settings.ALLOWED_HOSTS.append('testserver')

        self.results = []
        client = Client(raise_request_exception=False)

        superuser = get_user_model().objects.filter(is_superuser=True, is_active=True).first()
        if superuser is None:
            raise CommandError('admin.sqlite 里没有可用的超管账号，先运行 createsuperuser --database=django。')

        self._check_anonymous(client)
        client.force_login(superuser)
        self._check_lists_and_details(client)
        self._check_quest_admin(client)
        self._check_backups(client)
        self._check_permissions(client)

        fails = [row for row in self.results if not row[0]]
        self.stdout.write('\n===== 审计结果 =====')
        for ok, name, code, note in self.results:
            self.stdout.write(f"[{'PASS' if ok else 'FAIL'}] {name} -> HTTP {code} {note}")
        self.stdout.write(f"\n共 {len(self.results)} 项，失败 {len(fails)} 项。")
        self.stdout.write(f'登录身份: {superuser} (is_superuser={superuser.is_superuser})')
        if fails:
            raise SystemExit(1)

    # ------------------------------------------------------------------ 工具
    def _check(self, name, response, expect=(200,)):
        ok = response is not None and response.status_code in expect
        code = response.status_code if response is not None else '-'
        self.results.append((ok, name, code, 'OK' if ok else f'期望 {expect}'))
        return response

    def _flag(self, ok, name, note='OK'):
        self.results.append((bool(ok), name, 200, note if ok else note))
        return ok

    # ------------------------------------------------------------------ 各组
    def _check_anonymous(self, client):
        self._check('未登录 /admin/ → 302 登录', client.get('/admin/'), (302,))
        self._check('登录页渲染', client.get('/admin/login/?next=/admin/'), (200,))
        self._check('未登录 /media-thumb/ → 302', client.get('/media-thumb/xxx/'), (302,))
        self._check('未登录 记录抽屉 → 302', client.get('/admin/panel/entry/xxx/drawer/'), (302,))

    def _check_lists_and_details(self, client):
        self._check('仪表盘 /admin/', client.get('/admin/'))
        self._check('探索任务 · 搜索', client.get('/admin/panel/quest/?q=a'))
        self._check('探索任务 · 翻页', client.get('/admin/panel/quest/?page=2'))
        entry_list = self._check('记录列表', client.get('/admin/panel/entry/'))
        if entry_list is not None and entry_list.status_code == 200:
            entry_list_html = entry_list.content.decode('utf-8')
            self._flag('panel/record_drawer.js' in entry_list_html, '  └ 记录抽屉 JS 已引用（Media 注入）', 'record_drawer.js')
            self._flag('panel/record_drawer.css' in entry_list_html, '  └ 记录抽屉 CSS 已引用', 'record_drawer.css')
        self._check('媒体列表', client.get('/admin/panel/media/'))
        self._check('媒体绑定列表', client.get('/admin/panel/mediabinding/'))
        self._check('账号列表', client.get('/admin/panel/user/'))
        self._check('活动进度列表', client.get('/admin/panel/queststate/'))
        self._check('同步分支列表', client.get('/admin/panel/syncbranch/'))
        self._check('同步回执列表', client.get('/admin/panel/mutationreceipt/'))
        self._check('指令回执列表', client.get('/admin/panel/commandreceipt/'))
        self._check('删除墓碑列表', client.get('/admin/panel/entrytombstone/'))
        self._check('媒体清理队列', client.get('/admin/panel/mediacleanup/'))
        self._check('登录会话列表', client.get('/admin/panel/loginsession/'))
        self._check('服务端元数据', client.get('/admin/panel/servermetadata/'))
        self._check('客户端报错列表', client.get('/admin/panel/clientdiagnostic/'))
        self._check('客户端报错 change 直连 → 403', client.get('/admin/panel/clientdiagnostic/any/change/'), (403,))
        self._check('版本分发列表', client.get('/admin/panel/apkrelease/'))
        self._check('版本分发 change 直连 → 403', client.get('/admin/panel/apkrelease/any/change/'), (403,))
        self._check('版本分发 upload GET → 302', client.get('/admin/panel/apkrelease/upload/'), (302,))
        self._check('版本分发 delete GET → 302', client.get('/admin/panel/apkrelease/delete/x.apk/'), (302,))
        self._check('下载统计列表', client.get('/admin/panel/downloadevent/'))
        self._check('下载统计 change 直连 → 403', client.get('/admin/panel/downloadevent/any/change/'), (403,))

        samples = [
            (Entry.objects.order_by('-created_at').first(), '记录详情', '/admin/panel/entry/{}/change/'),
            (MediaBinding.objects.first(), '媒体绑定详情', '/admin/panel/mediabinding/{}/change/'),
            (QuestState.objects.first(), '活动进度详情', '/admin/panel/queststate/{}/change/'),
            (SyncBranch.objects.first(), '同步分支详情', '/admin/panel/syncbranch/{}/change/'),
            (MutationReceipt.objects.first(), '同步回执详情', '/admin/panel/mutationreceipt/{}/change/'),
            (CommandReceipt.objects.first(), '指令回执详情', '/admin/panel/commandreceipt/{}/change/'),
            (EntryTombstone.objects.first(), '删除墓碑详情', '/admin/panel/entrytombstone/{}/change/'),
            (MediaCleanup.objects.first(), '清理队列详情', '/admin/panel/mediacleanup/{}/change/'),
            (LoginSession.objects.first(), '登录会话详情', '/admin/panel/loginsession/{}/change/'),
            (ServerMetadata.objects.first(), '服务端元数据详情', '/admin/panel/servermetadata/{}/change/'),
            (SqUser.objects.first(), '账号详情', '/admin/panel/user/{}/change/'),
        ]
        for obj, label, pattern in samples:
            if obj is not None:
                self._check(label, client.get(pattern.format(obj.pk)))

        first_entry = Entry.objects.order_by('-created_at').first()
        if first_entry is not None:
            drawer = self._check('记录 · 抽屉 fragment', client.get(f'/admin/panel/entry/{first_entry.pk}/drawer/'))
            if drawer is not None and drawer.status_code == 200:
                drawer_html = drawer.content.decode('utf-8')
                self._flag('sqr-meta' in drawer_html and 'sqr-text' in drawer_html,
                           '  └ 抽屉含元信息与正文结构', 'sqr-meta/sqr-text')
            self._check('记录 · 抽屉（不存在的记录）→ 404', client.get('/admin/panel/entry/no-such-record/drawer/'), (404,))

        media = Media.objects.filter(status='ready', content_name__isnull=False).first()
        if media is not None:
            self._check(f'媒体详情（播放器）{media.id[:8]}', client.get(f'/admin/panel/media/{media.id}/change/'))
            self._check('媒体缩略图', client.get(f'/media-thumb/{media.id}/'))
            full = self._check('媒体文件完整返回', client.get(f'/media-file/{media.id}/'))
            if full is not None and full.status_code == 200:
                self._check('媒体文件 Range 206', client.get(f'/media-file/{media.id}/', HTTP_RANGE='bytes=0-99'), (206,))
                self._check('媒体文件越界 Range 416', client.get(f'/media-file/{media.id}/', HTTP_RANGE='bytes=99999999999-'), (416,))

    def _check_quest_admin(self, client):
        catalog_data = catalog.load_catalog()
        first_id = catalog_data[0]['id']
        listing = self._check('探索任务列表', client.get('/admin/panel/quest/'))
        if listing is not None and listing.status_code == 200:
            html = listing.content.decode('utf-8')
            self._flag('panel/quest_drawer.js' in html, '  └ 抽屉 JS 已引用（Media 注入）', 'quest_drawer.js')
            self._flag('panel/quest_diff.js' in html, '  └ 差异预览 JS 已引用', 'quest_diff.js')
            self._flag('panel/quest_drawer.css' in html, '  └ 抽屉 CSS 已引用', 'quest_drawer.css')
            self._flag('panel/quest_admin.css' in html, '  └ 主题层 CSS 已引用', 'quest_admin.css')
        self._check('探索任务 · 抽屉(新增)', client.get('/admin/panel/quest/?drawer=add'))
        self._check(f'探索任务 · 抽屉(view:{first_id})', client.get(f'/admin/panel/quest/?drawer=view:{first_id}'))
        self._check(f'探索任务 · 抽屉(edit:{first_id})', client.get(f'/admin/panel/quest/?drawer=edit:{first_id}'))

        bad = self._check('新增抽屉 · 校验失败重开', client.post('/admin/panel/quest/add/', {'id': '不合法ID!!', 'title': ''}), (200,))
        if bad is not None:
            self._flag('data-form-bound="1"' in bad.content.decode('utf-8', 'ignore'),
                       '  └ 校验失败标记 data-form-bound="1"', '存在' )
        self._check('编辑抽屉 · 校验失败重开', client.post(f'/admin/panel/quest/{first_id}/edit/', {'id': first_id, 'title': ''}), (200,))

        self._check('GET /add/ → 302 重定向', client.get('/admin/panel/quest/add/'), (302,))
        self._check('GET edit → 302 重定向', client.get(f'/admin/panel/quest/{first_id}/edit/'), (302,))
        self._check('GET toggle → 302 重定向', client.get(f'/admin/panel/quest/{first_id}/toggle/'), (302,))
        self._check('GET move → 302 重定向', client.get(f'/admin/panel/quest/{first_id}/move/'), (302,))

        self._check('探索任务 change 直连 → 403（0.3.x 修复）', client.get(f'/admin/panel/quest/{first_id}/change/'), (403,))
        self._check('探索任务 delete 直连 → 403', client.get(f'/admin/panel/quest/{first_id}/delete/'), (403,))
        self._check('探索任务 history 直连 → 403', client.get(f'/admin/panel/quest/{first_id}/history/'), (403,))

        check = catalog.CATALOG_PATH
        self._flag(check.exists(), 'catalog.json 存在', str(check))

    def _check_backups(self, client):
        backups_page = self._check('备份列表页', client.get('/admin/panel/quest/backups/'))
        if backups_page is not None and backups_page.status_code == 200:
            backups_html = backups_page.content.decode('utf-8')
            self._flag('panel/quest_admin.css' in backups_html, '  └ 备份页同时引用主题层 CSS', 'quest_admin.css')
        self._check('备份手动接口 GET → 302', client.get('/admin/panel/quest/backups/manual/'), (302,))
        self._check('备份下载 · 非法名 404', client.get('/admin/panel/quest/backups/evil.json/download/'), (404,))
        self._check('备份下载 · 不存在 404', client.get('/admin/panel/quest/backups/catalog-20200101-000000-manual.json/download/'), (404,))
        self._check('备份恢复 · GET → 302', client.get('/admin/panel/quest/backups/catalog-20200101-000000-manual.json/restore/'), (302,))
        self._check('备份恢复 · 非法名 POST → 302 带错误', client.post('/admin/panel/quest/backups/evil.json/restore/'), (302,))

    def _check_permissions(self, client):
        self._check('记录新增被禁', client.get('/admin/panel/entry/add/'), (403,))
        sample_user = SqUser.objects.first()
        if sample_user is not None:
            self._check('账号删除被禁', client.get(f'/admin/panel/user/{sample_user.id}/delete/'), (403,))
        sample_media = Media.objects.first()
        if sample_media is not None:
            self._check('媒体删除被禁', client.get(f'/admin/panel/media/{sample_media.id}/delete/'), (403,))
