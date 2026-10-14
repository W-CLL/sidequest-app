"""仪表盘数据：统计卡片、最近 7 天趋势图、最新记录列表。"""
import json
from collections import Counter
from datetime import datetime, timedelta, timezone

from .models import Entry, Media, User

CST = timezone(timedelta(hours=8))


def _to_cst(iso_text):
    try:
        return datetime.fromisoformat(iso_text.replace('Z', '+00:00')).astimezone(CST)
    except (ValueError, AttributeError):
        return None


def dashboard_callback(request, context):
    total_users = User.objects.count()
    total_entries = Entry.objects.count()
    media_total = Media.objects.count()
    media_ready = Media.objects.filter(status='ready').count()
    media_failed = Media.objects.filter(status='failed').count()

    today = datetime.now(CST).date()
    days = [today - timedelta(days=i) for i in range(6, -1, -1)]
    per_day = Counter()
    for (created,) in Entry.objects.values_list('created_at'):
        dt = _to_cst(created)
        if dt:
            per_day[dt.date()] += 1

    chart = {
        'labels': [d.strftime('%m-%d') for d in days],
        'datasets': [
            {
                'label': '新记录',
                'data': [per_day.get(d, 0) for d in days],
                'backgroundColor': '#234D3C',
                'borderRadius': 8,
                'maxBarThickness': 40,
            },
        ],
    }

    recent = []
    for entry in Entry.objects.select_related('user').order_by('-created_at')[:8]:
        dt = _to_cst(entry.created_at)
        recent.append(
            {
                'id': entry.id,
                'user': entry.user.nickname,
                'title': entry.quest_title,
                'text': entry.text[:38] + ('…' if len(entry.text) > 38 else ''),
                'time': dt.strftime('%m-%d %H:%M') if dt else '-',
            }
        )

    context.update(
        {
            'sq_stats': {
                'users': total_users,
                'entries': total_entries,
                'media_total': media_total,
                'media_ready': media_ready,
                'media_failed': media_failed,
            },
            'sq_chart': json.dumps(chart, ensure_ascii=False),
            'sq_recent': recent,
        }
    )
    return context
