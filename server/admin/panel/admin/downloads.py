"""下载统计页：读取 <SIDEQUEST_DOWNLOADS>（downloads.jsonl），聚合展示访问 / 下载 / 独立访客。

数据由主服务在 /download（落地页访问）与 /download/latest（下载请求）落盘。
只统计下载链接的公开访问——支线 App 不采集、不上报任何行为数据。
"""
import hashlib
import json
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

from django.conf import settings
from django.contrib import admin
from django.core.exceptions import PermissionDenied
from django.template.response import TemplateResponse

from panel.models import DownloadEvent

CST = timezone(timedelta(hours=8))
SOURCE_LABELS = {'wechat': '微信', 'qq': 'QQ', 'browser': '浏览器', 'other': '其他'}
VIA_LABELS = {'oss': 'OSS', 'server': '服务器'}


def _cst_time(value):
    try:
        return datetime.fromisoformat(str(value).replace('Z', '+00:00')).astimezone(CST)
    except (ValueError, TypeError):
        return None


def _visitor_key(row) -> str:
    raw = f"{row.get('ip') or ''}|{row.get('ua') or ''}"
    return hashlib.sha256(raw.encode('utf-8')).hexdigest()[:16]


def load_events(path: Path, limit: int = 20000):
    rows = []
    if not path.exists():
        return rows
    with path.open('r', encoding='utf-8', errors='replace') as handle:
        lines = handle.readlines()[-limit:]
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict) and item.get('type') in ('page', 'apk'):
            rows.append(item)
    return rows


@admin.register(DownloadEvent)
class DownloadEventAdmin(admin.ModelAdmin):
    PAGE_SIZE = 50
    RECENT_MAX = 400

    class Media:
        css = {'all': ('panel/quest_admin.css',)}

    def has_add_permission(self, request):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    # 直连 change/delete/history 一律拒绝：本页数据不在数据库里（同诊断页模式）
    def get_object(self, *args, **kwargs):
        raise PermissionDenied

    @staticmethod
    def _page_items(page: int, total_pages: int):
        if total_pages <= 7:
            return list(range(1, total_pages + 1))
        items = [1]
        if page > 3:
            items.append('…')
        for number in range(max(2, page - 1), min(total_pages - 1, page + 1) + 1):
            items.append(number)
        if page < total_pages - 2:
            items.append('…')
        items.append(total_pages)
        return items

    def changelist_view(self, request, extra_context=None):
        if not self.has_view_permission(request):
            raise PermissionDenied
        path = Path(settings.SIDEQUEST_DOWNLOADS)
        events = load_events(path)
        pages = [row for row in events if row.get('type') == 'page']
        downloads = [row for row in events if row.get('type') == 'apk']

        daily = {}
        for row in events:
            stamp = _cst_time(row.get('at'))
            if stamp is None:
                continue
            bucket = daily.setdefault(
                stamp.date(),
                {'page': 0, 'apk': 0, 'from_page': 0, 'visitors': set()},
            )
            bucket[row['type']] += 1
            bucket['visitors'].add(_visitor_key(row))
            if row['type'] == 'apk' and '/download' in str(row.get('referer') or ''):
                bucket['from_page'] += 1
        daily_rows = [
            {
                'date': day.isoformat(),
                'page': daily[day]['page'],
                'apk': daily[day]['apk'],
                'from_page': daily[day]['from_page'],
                'visitors': len(daily[day]['visitors']),
            }
            for day in sorted(daily, reverse=True)[:14]
        ]

        today = datetime.now(CST).date()
        today_bucket = daily.get(today, {'page': 0, 'apk': 0, 'visitors': set()})
        summary = {
            'page': len(pages),
            'apk': len(downloads),
            'visitors': len({_visitor_key(row) for row in events}),
            'today_page': today_bucket['page'],
            'today_apk': today_bucket['apk'],
            'today_visitors': len(today_bucket['visitors']),
            'oss': sum(1 for row in downloads if row.get('via') == 'oss'),
            'server': sum(1 for row in downloads if row.get('via') != 'oss'),
        }

        sources = Counter(str(row.get('source') or 'other') for row in downloads)
        source_rows = [
            {'label': SOURCE_LABELS.get(key, key), 'count': count}
            for key, count in sources.most_common()
        ]

        rows = list(reversed(events))[: self.RECENT_MAX]  # 最近事件，最新在上
        for row in rows:
            stamp = _cst_time(row.get('at'))
            row['at_label'] = (
                stamp.strftime('%Y-%m-%d %H:%M:%S') if stamp else str(row.get('at') or '—')
            )
            row['kind'] = '下载' if row['type'] == 'apk' else '访问'
            row['via_label'] = VIA_LABELS.get(str(row.get('via')), '')
            referer = str(row.get('referer') or '')
            row['referer_label'] = (
                '下载页' if '/download' in referer else (referer[:60] if referer else '直接打开')
            )

        total = len(rows)
        total_pages = max(1, (total + self.PAGE_SIZE - 1) // self.PAGE_SIZE)
        try:
            page = int(request.GET.get('page') or 1)
        except ValueError:
            page = 1
        page = min(max(1, page), total_pages)
        start = (page - 1) * self.PAGE_SIZE

        context = {
            **self.admin_site.each_context(request),
            'title': '下载统计',
            'media': self.media,  # 自定义页面不走默认 changelist：必须手动注入 Media
            'summary': summary,
            'daily_rows': daily_rows,
            'source_rows': source_rows,
            'rows': rows[start : start + self.PAGE_SIZE],
            'total': total,
            'page': page,
            'total_pages': total_pages,
            'page_items': self._page_items(page, total_pages),
            'page_start': start + 1 if total else 0,
            'page_end': min(start + self.PAGE_SIZE, total),
            'source_path': str(path),
        }
        return TemplateResponse(request, 'admin/panel/downloads_changelist.html', context)
