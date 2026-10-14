"""记录与删除墓碑。

- 记录：只读（用户数据）。列表「查看」走右侧抽屉（内容 + 媒体；媒体点击由灯箱弹窗接管），
  查看为页内抽屉、不做跳转；禁止新增，禁止编辑（change 直连 403）；允许删除。
- 删除墓碑：只读，用于排查「删除后又出现」或同步未收敛。
"""
from django.contrib import admin
from django.core.exceptions import PermissionDenied
from django.http import Http404
from django.template.response import TemplateResponse
from django.urls import path, reverse
from django.utils.html import format_html, format_html_join
from unfold.admin import ModelAdmin

from ..models import Entry, EntryTombstone, MediaBinding
from .helpers import cst_from_iso, short

DRAWER_THUMB_HEIGHT = 132


def media_items_html(entry, thumb_height=110):
    """记录的媒体附件（图片 → 灯箱；视频/音频 → 内嵌播放器）。列表列与抽屉共用。"""
    bindings = (
        MediaBinding.objects.filter(
            target_kind='entry', target_id=entry.id, user_id=entry.user_id
        )
        .select_related('media')
        .order_by('position')
    )
    items = []
    for binding in bindings:
        media = binding.media
        url = f'/media-file/{media.id}/'
        if media.status != 'ready' or not media.content_name:
            items.append(
                format_html(
                    '<span style="display:inline-block;padding:6px 10px;border:1px solid #e3e0d3;'
                    'border-radius:8px;font-size:12px">{}/{} · {}</span>',
                    media.kind,
                    media.mime_type,
                    media.status,
                )
            )
        elif media.kind == 'image':
            items.append(
                format_html(
                    '<a href="{0}" data-sq-media="{0}" data-sq-kind="image" '
                    'data-sq-group="entry-{2}" title="点击弹窗查看">'
                    '<img src="/media-thumb/{1}/" style="height:{3}px;border-radius:8px;'
                    'border:1px solid #e3e0d3;cursor:zoom-in" /></a>',
                    url,
                    media.id,
                    entry.id,
                    thumb_height,
                )
            )
        elif media.kind == 'video':
            items.append(
                format_html(
                    '<video controls preload="metadata" poster="/media-thumb/{0}/" src="{1}" '
                    'style="height:{2}px;border-radius:8px"></video>',
                    media.id,
                    url,
                    thumb_height,
                )
            )
        elif media.kind == 'audio':
            items.append(
                format_html(
                    '<audio controls src="{}" style="vertical-align:middle"></audio>',
                    url,
                )
            )
        else:
            items.append(
                format_html('<a href="{}" target="_blank">{}</a>', url, media.kind)
            )
    if not items:
        return None
    inner = format_html_join('', '{}', ((item,) for item in items))
    return format_html(
        '<div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center">{}</div>',
        inner,
    )


@admin.register(Entry)
class EntryAdmin(ModelAdmin):
    list_display = ('view_link', 'quest_title', 'user_nick', 'text_short', 'created_cst', 'revision', 'media_count')
    list_display_links = None
    list_filter = ('quest_id',)
    search_fields = ('text', 'quest_title', 'user__nickname')
    ordering = ('-created_at',)
    list_per_page = 50

    class Media:
        css = {'all': ('panel/media_modal.css', 'panel/record_drawer.css')}
        js = ('panel/media_modal.js', 'panel/record_drawer.js')

    readonly_fields = ('id', 'user', 'quest_id', 'quest_title', 'created_at', 'updated_at', 'revision', 'creation_hash', 'attachments')
    fields = ('id', 'user', 'quest_id', 'quest_title', 'text', 'attachments', 'created_at', 'updated_at', 'revision', 'creation_hash')

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        # 记录是用户数据：后台只读；查看走抽屉，不提供编辑入口。
        return False

    def change_view(self, request, object_id, form_url='', extra_context=None):
        # 查看只走抽屉：记录不提供独立的详情页/编辑页。
        raise PermissionDenied('记录为只读，请在列表中用「查看」抽屉浏览。')

    # ---- 记录抽屉（只读 fragment）------------------------------------------
    def get_urls(self):
        custom = [
            path(
                '<str:entry_id>/drawer/',
                self.admin_site.admin_view(self.record_drawer_view),
                name='panel_entry_drawer',
            ),
        ]
        return custom + super().get_urls()

    def record_drawer_view(self, request, entry_id):
        """记录抽屉 fragment：元信息 + 记录内容 + 媒体。由列表页 record_drawer.js 注入。"""
        if not self.has_view_permission(request):
            raise PermissionDenied('没有查看记录的权限。')
        entry = Entry.objects.select_related('user').filter(pk=entry_id).first()
        if entry is None:
            raise Http404('找不到这条记录。')
        media_count = MediaBinding.objects.filter(
            target_kind='entry', target_id=entry.id, user_id=entry.user_id
        ).count()
        media_html = media_items_html(entry, thumb_height=DRAWER_THUMB_HEIGHT)
        context = {
            'title': '记录详情',
            'entry': entry,
            'user_nick': entry.user.nickname if entry.user_id else '-',
            'created_cst': cst_from_iso(entry.created_at),
            'media_count': media_count,
            'media_html': media_html or format_html('<span style="color:#8a948c;font-size:13px">无</span>'),
        }
        return TemplateResponse(request, 'admin/panel/record_drawer.html', context)

    @admin.display(description='查看')
    def view_link(self, obj):
        # 无 href 的按钮：查看只开抽屉，永远不会跳转。
        return format_html(
            '<button type="button" class="sqr-open" data-sq-record="{}" data-sq-record-url="{}" '
            'title="抽屉查看记录内容与媒体">查看</button>',
            obj.pk,
            reverse('admin:panel_entry_drawer', args=[obj.pk]),
        )

    @admin.display(description='账号', ordering='user__nickname')
    def user_nick(self, obj):
        return obj.user.nickname if obj.user_id else '-'

    @admin.display(description='内容')
    def text_short(self, obj):
        return obj.text[:40] + '…' if len(obj.text) > 40 else obj.text

    @admin.display(description='创建时间', ordering='created_at')
    def created_cst(self, obj):
        return cst_from_iso(obj.created_at)

    @admin.display(description='附件数')
    def media_count(self, obj):
        return MediaBinding.objects.filter(
            target_kind='entry', target_id=obj.id, user_id=obj.user_id
        ).count()

    @admin.display(description='附件')
    def attachments(self, obj):
        return media_items_html(obj) or '无'


@admin.register(EntryTombstone)
class EntryTombstoneAdmin(ModelAdmin):
    list_display = ('id_short', 'user', 'creation_hash_short', 'deleted_cst')
    search_fields = ('id', 'user__nickname')
    ordering = ('-deleted_at',)
    list_per_page = 50

    def get_readonly_fields(self, request, obj=None):
        return [f.name for f in self.model._meta.fields]

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    @admin.display(description='记录 ID')
    def id_short(self, obj):
        return short(obj.id, 12)

    @admin.display(description='创建哈希')
    def creation_hash_short(self, obj):
        return short(obj.creation_hash, 12)

    @admin.display(description='删除时间', ordering='deleted_at')
    def deleted_cst(self, obj):
        return cst_from_iso(obj.deleted_at)
