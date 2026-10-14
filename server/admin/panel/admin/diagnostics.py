"""客户端报错页：读取 <SIDEQUEST_DIAGNOSTICS>（diagnostics.jsonl），只读、分页展示最近条目。

数据由主服务 /api/diagnostics 端点落盘（客户端 lib/silent_reporter.dart 静默上报），
此页不触碰任何数据库表。
"""
import json
from pathlib import Path

from django.conf import settings
from django.contrib import admin
from django.core.exceptions import PermissionDenied
from django.template.response import TemplateResponse

from panel.models import ClientDiagnostic, User


@admin.register(ClientDiagnostic)
class ClientDiagnosticAdmin(admin.ModelAdmin):
    MAX_ROWS = 200

    class Media:
        css = {'all': ('panel/quest_admin.css',)}

    def has_add_permission(self, request):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    # 直连 change/delete/history 一律拒绝：本页数据不在数据库里（同 Quest 模式）
    def get_object(self, *args, **kwargs):
        raise PermissionDenied

    def changelist_view(self, request, extra_context=None):
        if not self.has_view_permission(request):
            raise PermissionDenied
        path = Path(settings.SIDEQUEST_DIAGNOSTICS)
        rows = []
        if path.exists():
            with path.open('r', encoding='utf-8', errors='replace') as handle:
                lines = handle.readlines()[-self.MAX_ROWS:]
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                if isinstance(item, dict):
                    rows.append(item)
            rows.reverse()  # 最新在上

        nicknames = {}
        account_ids = {row.get('accountId') for row in rows if row.get('accountId')}
        if account_ids:
            nicknames = dict(
                User.objects.filter(id__in=account_ids).values_list('id', 'nickname')
            )
        for row in rows:
            row['account_label'] = nicknames.get(row.get('accountId')) or row.get('accountId') or ''

        context = {
            **self.admin_site.each_context(request),
            'title': '客户端报错',
            'media': self.media,  # 自定义页面不走默认 changelist：必须手动注入 Media，模板里渲染 {{ media.css }}
            'rows': rows,
            'total_shown': len(rows),
            'source_path': str(path),
        }
        return TemplateResponse(request, 'admin/panel/diagnostics_changelist.html', context)
