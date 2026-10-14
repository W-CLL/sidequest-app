"""探索任务目录的列表页（数据在 server/catalog.json，不落库）。

- 列表：搜索 + 每页 20 条服务端分页 + 分类/停用统计。
- 查看 / 新增 / 编辑走抽屉（quest_drawer），备份与回滚见 quest_backups。
- 目录不在数据库里：get_object 直接拒绝，避免默认 change/delete/history 视图
  去查询不存在的占位表（quest_catalog_stub）而 500。
"""
from urllib.parse import urlencode

from django.contrib import admin
from django.core.exceptions import PermissionDenied
from django.template.response import TemplateResponse
from django.urls import reverse
from unfold.admin import ModelAdmin

from ..catalog import CATEGORIES, ORIGINAL_COUNT, ROLE_LABELS, QuestForm, load_catalog
from ..models import Quest
from .quest_backups import QuestBackupsMixin
from .quest_drawer import QuestDrawerMixin

PAGE_SIZE = 20


@admin.register(Quest)
class QuestAdmin(QuestDrawerMixin, QuestBackupsMixin, ModelAdmin):
    class Media:
        css = {'all': ('panel/quest_admin.css', 'panel/quest_drawer.css')}
        js = ('panel/quest_diff.js', 'panel/quest_drawer.js')

    def has_add_permission(self, request):
        return True

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def get_object(self, request, object_id, from_field=None):
        # 目录数据不在数据库里：默认视图（change/delete/history）会先按主键取对象，
        # 从而查询不存在的占位表。后台只通过抽屉与自定义路由查看/编辑。
        raise PermissionDenied('探索任务请在列表中通过抽屉查看与编辑。')

    # ---- 渲染辅助 ----------------------------------------------------------
    def _page_items(self, page, total_pages):
        if total_pages <= 7:
            return list(range(1, total_pages + 1))
        numbers = sorted({1, 2, total_pages - 1, total_pages, page - 1, page, page + 1})
        numbers = [number for number in numbers if 1 <= number <= total_pages]
        items, previous = [], 0
        for number in numbers:
            if number - previous > 1:
                items.append('…')
            items.append(number)
            previous = number
        return items

    def _list_url(self, request, **params):
        source = request.POST if request.method == 'POST' else request.GET
        query = {}
        if source.get('q'):
            query['q'] = source.get('q')
        page = source.get('page')
        if page and page != '1':
            query['page'] = page
        query.update({key: value for key, value in params.items() if value})
        url = reverse('admin:panel_quest_changelist')
        return url + ('?' + urlencode(query) if query else '')

    def _flash_messages(self, source):
        """列表页顶部的提示条（成功 / 失败两类）。"""
        flash = ''
        error = (source.get('error') or '').strip()
        if source.get('added'):
            flash = (
                f"已新增「{source['added']}」：目录已更新并重新生成客户端文件"
                "（重启服务端后进入推荐，App 需重建后显示）。"
            )
        elif source.get('saved'):
            flash = f"已保存「{source['saved']}」：目录与客户端生成文件已同步更新。"
        elif source.get('moved'):
            direction = '上移' if source.get('dir') == 'up' else '下移'
            flash = f"已{direction}「{source['moved']}」：目录与客户端生成文件已同步更新。"
        elif source.get('toggled'):
            state = '停用' if source.get('now') == 'off' else '启用'
            note = '不再被推荐（服务端重启后生效），历史记录不受影响' if state == '停用' else '重新参与推荐（服务端重启后生效）'
            flash = f"已{state}「{source['toggled']}」：{note}；客户端生成文件已同步更新。"
        return flash, error

    def _render(self, request, *, form=None, drawer_mode='', drawer_id='', drawer_error='', form_bound=False):
        catalog = load_catalog()
        positions = {quest['id']: index + 1 for index, quest in enumerate(catalog)}
        source = request.POST if request.method == 'POST' else request.GET
        keyword = (source.get('q') or '').strip()
        needle = keyword.lower()
        filtered = [
            quest for quest in catalog
            if not needle
            or needle in quest['id'].lower()
            or needle in quest['title'].lower()
            or needle in quest['subtitle'].lower()
        ]
        total = len(filtered)
        total_pages = max(1, (total + PAGE_SIZE - 1) // PAGE_SIZE)
        try:
            page = int(source.get('page') or 1)
        except (TypeError, ValueError):
            page = 1
        page = min(max(page, 1), total_pages)
        start = (page - 1) * PAGE_SIZE
        rows = [
            {
                **quest,
                'position': positions[quest['id']],
                'locked': positions[quest['id']] <= ORIGINAL_COUNT,
                'is_enabled': quest.get('enabled') is not False,
            }
            for quest in filtered[start:start + PAGE_SIZE]
        ]

        flash, error = self._flash_messages(source)
        drawer_form = form or QuestForm()
        context = {
            **self.admin_site.each_context(request),
            'title': '探索任务',
            'media': self.media,  # 自定义页面不走 ModelAdmin.changelist_view：必须手动注入 Media，模板里渲染 {{ media.css }}/{{ media.js }}
            'quests': rows,
            'total': total,
            'catalog_total': len(catalog),
            'disabled_count': sum(1 for quest in catalog if quest.get('enabled') is False),
            'category_counts': [
                (name, sum(1 for item in catalog if item['category'] == name))
                for name in CATEGORIES
            ],
            'q': keyword,
            'page': page,
            'total_pages': total_pages,
            'page_items': self._page_items(page, total_pages),
            'page_start': start + 1 if total else 0,
            'page_end': min(start + PAGE_SIZE, total),
            'flash': flash,
            'error': error,
            'drawer_mode': drawer_mode,
            'drawer_id': drawer_id,
            'drawer_error': drawer_error,
            'drawer_form': drawer_form,
            'role_fields': [drawer_form[f'role_{role}'] for role in ROLE_LABELS],
            'form_bound': form_bound,
            'quests_json': catalog,
            'roles_json': ROLE_LABELS,
            'original_count': ORIGINAL_COUNT,
        }
        return TemplateResponse(request, 'admin/panel/quest_changelist.html', context)

    # ---- 视图 --------------------------------------------------------------
    def changelist_view(self, request, extra_context=None):
        drawer_mode, drawer_id = '', ''
        drawer_raw = (request.GET.get('drawer') or '').strip()
        if drawer_raw:
            if ':' in drawer_raw:
                drawer_mode, drawer_id = drawer_raw.split(':', 1)
            else:
                drawer_mode = drawer_raw
            if drawer_mode not in {'add', 'view', 'edit'}:
                drawer_mode, drawer_id = '', ''
        return self._render(request, drawer_mode=drawer_mode, drawer_id=drawer_id)
