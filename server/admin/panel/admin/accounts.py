"""账号与登录会话：只读页面。

账号删除必须走服务端流程（级联 + 会话失效），后台刻意不提供；
登录会话只负责展示（区分是否过期），撤销请走服务端流程。
"""
import time

from django.contrib import admin
from django.utils.html import format_html
from unfold.admin import ModelAdmin

from ..models import LoginSession, User
from .helpers import cst_from_ms, short


@admin.register(User)
class UserAdmin(ModelAdmin):
    list_display = ('nickname', 'role', 'preferences', 'entry_count', 'media_count', 'id_short')
    search_fields = ('nickname',)
    ordering = ('nickname',)
    list_per_page = 50

    def get_readonly_fields(self, request, obj=None):
        return [f.name for f in self.model._meta.fields]

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    @admin.display(description='记录数')
    def entry_count(self, obj):
        return obj.entries.count()

    @admin.display(description='媒体数')
    def media_count(self, obj):
        return obj.media.count()

    @admin.display(description='ID')
    def id_short(self, obj):
        return short(obj.id)


@admin.register(LoginSession)
class LoginSessionAdmin(ModelAdmin):
    list_display = ('token_short', 'user', 'expires_cst', 'validity')
    search_fields = ('user__nickname',)
    ordering = ('-expires_at',)
    list_per_page = 50

    def get_readonly_fields(self, request, obj=None):
        return [f.name for f in self.model._meta.fields]

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    @admin.display(description='令牌哈希')
    def token_short(self, obj):
        return short(obj.token_hash, 12)

    @admin.display(description='过期时间')
    def expires_cst(self, obj):
        return cst_from_ms(obj.expires_at)

    @admin.display(description='状态')
    def validity(self, obj):
        if obj.expires_at and obj.expires_at > time.time() * 1000:
            return format_html('<span style="color:#15803d">{}</span>', '有效')
        return format_html('<span style="color:#b42318">{}</span>', '已过期')
