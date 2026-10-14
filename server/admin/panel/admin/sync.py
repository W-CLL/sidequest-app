"""同步协议排查：同步分支、同步回执、指令回执（全部只读）。

卡在同步 / 疑似重放不一致时：对照 request_hash 与 result / receipt 排查。
"""
from django.contrib import admin
from unfold.admin import ModelAdmin

from ..models import CommandReceipt, MutationReceipt, SyncBranch
from .helpers import short


@admin.register(SyncBranch)
class SyncBranchAdmin(ModelAdmin):
    list_display = ('id_short', 'user', 'mode', 'base_revision', 'last_revision')
    list_filter = ('mode',)
    search_fields = ('id', 'user__nickname')
    list_per_page = 50

    def get_readonly_fields(self, request, obj=None):
        return [f.name for f in self.model._meta.fields]

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    @admin.display(description='分支 ID')
    def id_short(self, obj):
        return short(obj.id, 12)


@admin.register(MutationReceipt)
class MutationReceiptAdmin(ModelAdmin):
    list_display = ('id_short', 'user', 'request_hash_short', 'result_short')
    search_fields = ('id', 'user__nickname')
    list_per_page = 50

    def get_readonly_fields(self, request, obj=None):
        return [f.name for f in self.model._meta.fields]

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    @admin.display(description='请求 ID')
    def id_short(self, obj):
        return short(obj.id, 12)

    @admin.display(description='请求哈希')
    def request_hash_short(self, obj):
        return short(obj.request_hash, 12)

    @admin.display(description='处理结果')
    def result_short(self, obj):
        text = obj.result or ''
        return text[:70] + ('…' if len(text) > 70 else '')


@admin.register(CommandReceipt)
class CommandReceiptAdmin(ModelAdmin):
    list_display = ('id_short', 'user', 'branch_short', 'request_hash_short', 'receipt_short')
    search_fields = ('id', 'branch_id', 'user__nickname')
    list_per_page = 50

    def get_readonly_fields(self, request, obj=None):
        return [f.name for f in self.model._meta.fields]

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    @admin.display(description='指令 ID')
    def id_short(self, obj):
        return short(obj.id, 12)

    @admin.display(description='分支 ID')
    def branch_short(self, obj):
        return short(obj.branch_id, 12)

    @admin.display(description='请求哈希')
    def request_hash_short(self, obj):
        return short(obj.request_hash, 12)

    @admin.display(description='指令回执')
    def receipt_short(self, obj):
        text = obj.receipt or ''
        return text[:70] + ('…' if len(text) > 70 else '')
