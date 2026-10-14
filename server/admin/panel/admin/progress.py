"""活动进度注册：查看 + 编辑（修数据用），禁止新增/删除。"""
from django.contrib import admin
from unfold.admin import ModelAdmin

from ..models import QuestState


@admin.register(QuestState)
class QuestStateAdmin(ModelAdmin):
    list_display = ('user', 'day', 'active_quest_id', 'recommended_quest_id', 'progress_revision', 'can_request_next')
    search_fields = ('user__nickname',)
    ordering = ('user__nickname',)
    list_per_page = 50
    readonly_fields = ('user',)

    def has_add_permission(self, request):
        return False

    def has_delete_permission(self, request, obj=None):
        return False
