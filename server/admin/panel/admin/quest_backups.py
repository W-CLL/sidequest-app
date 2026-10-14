"""探索任务备份与回滚：列表 / 手动备份 / 下载 / 恢复。

每次目录改动（新增/编辑/停用/排序/恢复）都会在写盘前自动落盘一份备份；
恢复走与其他写操作相同的「备份 → 写盘 → 生成脚本校验，失败回滚」流程。
"""
from urllib.parse import urlencode

from django.core.exceptions import PermissionDenied
from django.http import FileResponse, Http404, HttpResponseRedirect
from django.template.response import TemplateResponse
from django.urls import path, reverse

from ..catalog import QuestSaveError, backups, catalog_text, load_catalog, restore_backup


class QuestBackupsMixin:
    def get_urls(self):
        return [
            path('backups/', self.admin_site.admin_view(self.quest_backups_view), name='panel_quest_backups'),
            path('backups/manual/', self.admin_site.admin_view(self.quest_backup_manual_view), name='panel_quest_backup_manual'),
            path('backups/<str:name>/download/', self.admin_site.admin_view(self.quest_backup_download_view), name='panel_quest_backup_download'),
            path('backups/<str:name>/restore/', self.admin_site.admin_view(self.quest_backup_restore_view), name='panel_quest_backup_restore'),
        ] + super().get_urls()

    def _backups_url(self, **params):
        url = reverse('admin:panel_quest_backups')
        query = {key: value for key, value in params.items() if value}
        return url + ('?' + urlencode(query) if query else '')

    def quest_backups_view(self, request):
        if not self.has_add_permission(request):
            raise PermissionDenied
        source = request.GET
        flash = ''
        if source.get('created'):
            flash = '已生成手动备份。'
        elif source.get('restored'):
            flash = f"已从「{source['restored']}」恢复目录：客户端生成文件已同步更新。"
        elif source.get('same'):
            flash = '备份内容与当前目录一致，无需恢复。'
        context = {
            **self.admin_site.each_context(request),
            'title': '探索任务备份',
            'media': self.media,
            'backups': backups.list_backups(),
            'catalog_total': len(load_catalog()),
            'backup_dir': str(backups.BACKUP_DIR),
            'keep': backups.KEEP,
            'flash': flash,
            'error': (source.get('error') or '').strip(),
        }
        return TemplateResponse(request, 'admin/panel/quest_backups.html', context)

    def quest_backup_manual_view(self, request):
        if not self.has_add_permission(request):
            raise PermissionDenied
        if request.method != 'POST':
            return HttpResponseRedirect(self._backups_url())
        try:
            backups.create_backup(catalog_text(), 'manual')
        except QuestSaveError as exc:
            return HttpResponseRedirect(self._backups_url(error=str(exc)))
        return HttpResponseRedirect(self._backups_url(created='1'))

    def quest_backup_download_view(self, request, name):
        if not self.has_add_permission(request):
            raise PermissionDenied
        try:
            path = backups.resolve_backup(name)
        except QuestSaveError as exc:
            raise Http404(str(exc)) from exc
        return FileResponse(open(path, 'rb'), as_attachment=True, filename=name)

    def quest_backup_restore_view(self, request, name):
        if not self.has_add_permission(request):
            raise PermissionDenied
        if request.method != 'POST':
            return HttpResponseRedirect(self._backups_url())
        try:
            changed = restore_backup(name)
        except QuestSaveError as exc:
            return HttpResponseRedirect(self._backups_url(error=str(exc)))
        if not changed:
            return HttpResponseRedirect(self._backups_url(same=name))
        return HttpResponseRedirect(self._backups_url(restored=name))
