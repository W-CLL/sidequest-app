"""服务端元数据：只读（协议版本等运行时键值）。"""
from django.contrib import admin
from unfold.admin import ModelAdmin

from ..models import ServerMetadata


@admin.register(ServerMetadata)
class ServerMetadataAdmin(ModelAdmin):
    list_display = ('key', 'value_short')
    search_fields = ('key', 'value')
    ordering = ('key',)
    list_per_page = 50

    def get_readonly_fields(self, request, obj=None):
        return [f.name for f in self.model._meta.fields]

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    @admin.display(description='值')
    def value_short(self, obj):
        text = obj.value or ''
        return text[:90] + ('…' if len(text) > 90 else '')
