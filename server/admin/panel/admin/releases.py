"""版本分发页：上传 / 列出 / 删除 APK 文件。

主页面的 /download 与 /download/latest 始终指向目录里最新（按修改时间）的
.apk——所以这里上传后不需要再做任何事，下载链接会自动切换。
"""
from datetime import datetime
from pathlib import Path
import urllib.request
from urllib.parse import quote

from django.conf import settings
from django.contrib import admin
from django.core.exceptions import PermissionDenied
from django.http import HttpResponseRedirect
from django.template.response import TemplateResponse
from django.urls import path, reverse

from panel.models import ApkRelease

MAX_UPLOAD_BYTES = 400 * 1024 * 1024


def apk_directory() -> Path:
    return Path(settings.SIDEQUEST_APK_DIR)


def warm_oss() -> None:
    """通知主服务把最新 APK 预热到 OSS（尽力而为；失败不影响上传，下载时会自动重试）。"""
    try:
        request = urllib.request.Request(
            'http://127.0.0.1:8787/internal/oss-warm', method='POST', data=b''
        )
        urllib.request.urlopen(request, timeout=1.5).read()
    except Exception:  # noqa: BLE001 - 预热只是可选加速
        pass


def list_apks():
    directory = apk_directory()
    items = []
    if directory.exists():
        entries = [
            entry
            for entry in directory.iterdir()
            if entry.is_file() and entry.suffix.lower() == '.apk'
        ]
        entries.sort(key=lambda entry: entry.stat().st_mtime, reverse=True)
        for entry in entries:
            stat = entry.stat()
            items.append(
                {
                    'name': entry.name,
                    'size_label': f'{stat.st_size / (1024 * 1024):.1f} MB',
                    'updated': datetime.fromtimestamp(stat.st_mtime).strftime(
                        '%Y-%m-%d %H:%M'
                    ),
                    'is_current': False,
                }
            )
    if items:
        items[0]['is_current'] = True
    return items


def safe_name(raw):
    """只接受纯文件名（无路径分隔符）、以 .apk 结尾、无 Windows 非法字符。"""
    name = (raw or '').strip()
    if not name or name != Path(name).name or not name.lower().endswith('.apk'):
        return None
    if any(char in name for char in '\\/:*?"<>|'):
        return None
    return name


@admin.register(ApkRelease)
class ApkReleaseAdmin(admin.ModelAdmin):
    class Media:
        css = {'all': ('panel/quest_admin.css',)}

    def has_add_permission(self, request):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    # 直连 change/delete/history 一律拒绝：本页数据是文件不是数据库行（同 Quest 模式）
    def get_object(self, *args, **kwargs):
        raise PermissionDenied

    def get_urls(self):
        custom = [
            path(
                'upload/',
                self.admin_site.admin_view(self.upload_view),
                name='panel_apkrelease_upload',
            ),
            path(
                'delete/<str:name>/',
                self.admin_site.admin_view(self.delete_view),
                name='panel_apkrelease_delete',
            ),
        ]
        return custom + super().get_urls()

    def _guard(self, request):
        if not self.has_view_permission(request):
            raise PermissionDenied

    def _changelist(self, **params):
        url = reverse('admin:panel_apkrelease_changelist')
        if params:
            url += '?' + '&'.join(
                f'{key}={quote(str(value))}' for key, value in params.items()
            )
        return HttpResponseRedirect(url)

    def changelist_view(self, request, extra_context=None):
        self._guard(request)
        if request.method != 'GET':
            return self._changelist()
        base = settings.SIDEQUEST_PUBLIC_BASE_URL
        context = {
            **self.admin_site.each_context(request),
            'title': '版本分发',
            'media': self.media,  # 自定义页面必须手动注入 Media（模板里渲染 {{ media.css }}）
            'apks': list_apks(),
            'apk_dir': str(apk_directory()),
            'download_page_url': f'{base}/download' if base else '',
            'download_latest_url': f'{base}/download/latest' if base else '',
            'flash': request.GET.get('flash') or '',
            'error': request.GET.get('error') or '',
        }
        return TemplateResponse(
            request, 'admin/panel/releases_changelist.html', context
        )

    def upload_view(self, request):
        self._guard(request)
        if request.method != 'POST':
            return self._changelist()
        upload = request.FILES.get('apk')
        if upload is None:
            return self._changelist(error='请先选择要上传的 APK 文件')
        if upload.size > MAX_UPLOAD_BYTES:
            return self._changelist(error='文件超过 400 MB，请确认是不是完整的安装包')
        name = safe_name(upload.name)
        if name is None:
            return self._changelist(error='文件名不合法（需要以 .apk 结尾的纯文件名）')
        head = upload.read(4)
        if head[:2] != b'PK':
            return self._changelist(error='这不像是有效的安装包（APK 应为 zip 格式）')
        directory = apk_directory()
        directory.mkdir(parents=True, exist_ok=True)
        staging = directory / f'.{name}.uploading'
        with staging.open('wb') as handle:
            handle.write(head)
            for chunk in upload.chunks():
                handle.write(chunk)
        staging.replace(directory / name)
        warm_oss()
        return self._changelist(flash=f'已上传 {name}；下载链接自动指向最新包')

    def delete_view(self, request, name):
        self._guard(request)
        if request.method != 'POST':
            return self._changelist()
        safe = safe_name(name)
        target = apk_directory() / safe if safe else None
        if target is None or not target.is_file():
            return self._changelist(error='没有找到这个文件（可能已被删除）')
        target.unlink()
        return self._changelist(flash=f'已删除 {safe}')
