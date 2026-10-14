"""媒体、媒体绑定与清理队列：只读页面。

- 媒体：详情内嵌播放器（灯箱弹窗经 media_modal.js 接管），禁止增删改。
- 媒体绑定：只读。
- 清理队列：查看「删除失败待重试」的媒体（attempts / last_error 是排查关键）。
"""
from django.contrib import admin
from django.utils.html import format_html
from unfold.admin import ModelAdmin

from ..models import Media, MediaBinding, MediaCleanup
from .helpers import cst_from_ms, cst_from_iso, format_size, short


@admin.register(Media)
class MediaAdmin(ModelAdmin):
    list_display = ('id_short', 'user_nick', 'kind', 'status', 'size_h', 'dims', 'thumb', 'created_cst')
    list_filter = ('kind', 'status')
    search_fields = ('id', 'client_upload_id', 'user__nickname')
    ordering = ('-created_at',)
    list_per_page = 50

    def get_readonly_fields(self, request, obj=None):
        return ['player'] + [f.name for f in self.model._meta.fields]

    def get_fields(self, request, obj=None):
        return ('player',) + tuple(f.name for f in self.model._meta.fields)

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    class Media:
        css = {'all': ('panel/media_modal.css',)}
        js = ('panel/media_modal.js',)

    @admin.display(description='ID')
    def id_short(self, obj):
        return format_html('<a href="/admin/panel/media/{}/change/">{}</a>', obj.id, short(obj.id))

    @admin.display(description='账号', ordering='user__nickname')
    def user_nick(self, obj):
        return obj.user.nickname if obj.user_id else '-'

    @admin.display(description='大小')
    def size_h(self, obj):
        return format_size(obj.byte_size)

    @admin.display(description='尺寸/时长')
    def dims(self, obj):
        parts = []
        if obj.width and obj.height:
            parts.append(f'{obj.width}×{obj.height}')
        if obj.duration_ms:
            parts.append(f'{obj.duration_ms / 1000:.1f}s')
        return ' · '.join(parts) or '-'

    @admin.display(description='预览')
    def thumb(self, obj):
        if not obj.content_name:
            return '—'
        url = f'/media-file/{obj.id}/'
        if obj.thumbnail_name:
            return format_html(
                '<a href="{0}" data-sq-media="{0}" data-sq-kind="{1}" title="点击弹窗查看/播放">'
                '<img src="/media-thumb/{2}/" style="height:52px;border-radius:6px;'
                'border:1px solid #e3e0d3;cursor:zoom-in" /></a>',
                url,
                obj.kind,
                obj.id,
            )
        if obj.kind == 'video':
            return format_html('<a href="{0}" data-sq-media="{0}" data-sq-kind="video">▶ 播放</a>', url)
        if obj.kind == 'audio':
            return format_html('<a href="{0}" data-sq-media="{0}" data-sq-kind="audio">♫ 试听</a>', url)
        return '—'

    @admin.display(description='预览与播放')
    def player(self, obj):
        if obj.status != 'ready' or not obj.content_name:
            return format_html(
                '<span style="color:#b45309">文件不可用（status={}）</span>', obj.status
            )
        url = f'/media-file/{obj.id}/'
        if obj.kind == 'image':
            return format_html(
                '<a href="{0}" data-sq-media="{0}" data-sq-kind="image" title="点击弹窗查看">'
                '<img src="{0}" style="max-width:100%;max-height:520px;border-radius:10px;'
                'border:1px solid #e3e0d3;cursor:zoom-in" /></a>',
                url,
            )
        if obj.kind == 'video':
            return format_html(
                '<video controls preload="metadata" style="max-width:100%;max-height:520px;'
                'border-radius:10px" src="{}"></video>',
                url,
            )
        if obj.kind == 'audio':
            return format_html('<audio controls style="width:100%" src="{}"></audio>', url)
        return format_html('<a href="{}" target="_blank">打开文件</a>', url)

    @admin.display(description='创建时间', ordering='created_at')
    def created_cst(self, obj):
        return cst_from_ms(obj.created_at)


@admin.register(MediaBinding)
class MediaBindingAdmin(ModelAdmin):
    list_display = ('media', 'user', 'target_kind', 'target_short', 'position')
    list_filter = ('target_kind',)
    search_fields = ('media_id', 'target_id', 'user__nickname')
    list_per_page = 50

    def get_readonly_fields(self, request, obj=None):
        return [f.name for f in self.model._meta.fields]

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    @admin.display(description='目标 ID')
    def target_short(self, obj):
        return short(obj.target_id, 12)


@admin.register(MediaCleanup)
class MediaCleanupAdmin(ModelAdmin):
    list_display = ('media_short', 'media_kind', 'attempts', 'created_cst', 'error_short')
    search_fields = ('media_id',)
    ordering = ('created_at',)
    list_per_page = 50

    def get_readonly_fields(self, request, obj=None):
        return [f.name for f in self.model._meta.fields]

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    @admin.display(description='媒体 ID')
    def media_short(self, obj):
        return format_html('<a href="/admin/panel/media/{}/change/">{}</a>', obj.media_id, short(obj.media_id, 12))

    @admin.display(description='类型')
    def media_kind(self, obj):
        return Media.objects.filter(id=obj.media_id).values_list('kind', flat=True).first() or '—（媒体已删除）'

    @admin.display(description='入队时间', ordering='created_at')
    def created_cst(self, obj):
        return cst_from_ms(obj.created_at)

    @admin.display(description='最近错误')
    def error_short(self, obj):
        if not obj.last_error:
            return '—'
        return obj.last_error[:80] + ('…' if len(obj.last_error) > 80 else '')
