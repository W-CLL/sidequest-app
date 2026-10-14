"""探索任务抽屉相关路由：新增 / 编辑 / 停用切换 / 排序。

由 QuestAdmin 继承；依赖宿主提供的 _render / _list_url / has_add_permission。
所有 GET 到写路由的请求都会被重定向回列表（写操作只接受 POST + CSRF）。
"""
from django.core.exceptions import PermissionDenied
from django.http import Http404, HttpResponseRedirect
from django.urls import path

from ..catalog import (
    QuestForm,
    QuestSaveError,
    append_quest,
    load_catalog,
    move_quest,
    set_enabled,
    update_quest,
)


class QuestDrawerMixin:
    def get_urls(self):
        return [
            path('add/', self.admin_site.admin_view(self.quest_add_view), name='panel_quest_add'),
            path('<str:quest_id>/edit/', self.admin_site.admin_view(self.quest_edit_view), name='panel_quest_edit'),
            path('<str:quest_id>/toggle/', self.admin_site.admin_view(self.quest_toggle_view), name='panel_quest_toggle'),
            path('<str:quest_id>/move/', self.admin_site.admin_view(self.quest_move_view), name='panel_quest_move'),
        ] + super().get_urls()

    def _find_quest(self, quest_id):
        quest = next((item for item in load_catalog() if item['id'] == quest_id), None)
        if quest is None:
            raise Http404('找不到该活动。')
        return quest

    def quest_add_view(self, request):
        if not self.has_add_permission(request):
            raise PermissionDenied
        if request.method != 'POST':
            return HttpResponseRedirect(self._list_url(request, drawer='add'))
        form = QuestForm(request.POST)
        if form.is_valid():
            try:
                added_id = append_quest(form.build_quest())
            except QuestSaveError as exc:
                return self._render(request, form=form, drawer_mode='add',
                                    drawer_error=str(exc), form_bound=True)
            return HttpResponseRedirect(self._list_url(request, added=added_id))
        return self._render(request, form=form, drawer_mode='add', form_bound=True)

    def quest_edit_view(self, request, quest_id):
        if not self.has_add_permission(request):
            raise PermissionDenied
        if request.method != 'POST':
            return HttpResponseRedirect(self._list_url(request, drawer=f'edit:{quest_id}'))
        form = QuestForm(request.POST, editing_id=quest_id)
        if form.is_valid():
            try:
                update_quest(quest_id, form.build_quest())
            except QuestSaveError as exc:
                return self._render(request, form=form, drawer_mode='edit', drawer_id=quest_id,
                                    drawer_error=str(exc), form_bound=True)
            return HttpResponseRedirect(self._list_url(request, saved=quest_id))
        return self._render(request, form=form, drawer_mode='edit', drawer_id=quest_id, form_bound=True)

    def quest_toggle_view(self, request, quest_id):
        """停用 / 启用一条任务（停用 = 不再被推荐，历史与已激活任务不受影响）。"""
        if not self.has_add_permission(request):
            raise PermissionDenied
        if request.method != 'POST':
            return HttpResponseRedirect(self._list_url(request))
        quest = self._find_quest(quest_id)
        currently_enabled = quest.get('enabled') is not False
        try:
            set_enabled(quest_id, not currently_enabled)
        except QuestSaveError as exc:
            return HttpResponseRedirect(self._list_url(request, error=str(exc)))
        return HttpResponseRedirect(self._list_url(
            request, toggled=quest_id, now='off' if currently_enabled else 'on'
        ))

    def quest_move_view(self, request, quest_id):
        """在原始 16 条之后的可调整范围内上移/下移（原始任务顺序被生成脚本锁定）。"""
        if not self.has_add_permission(request):
            raise PermissionDenied
        if request.method != 'POST':
            return HttpResponseRedirect(self._list_url(request))
        direction = request.POST.get('dir') or ''
        try:
            move_quest(quest_id, direction)
        except QuestSaveError as exc:
            return HttpResponseRedirect(self._list_url(request, error=str(exc)))
        return HttpResponseRedirect(self._list_url(request, moved=quest_id, dir=direction))
