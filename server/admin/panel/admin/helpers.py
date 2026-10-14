"""后台共用：时区格式化、字段缩略与大小格式化。"""
from datetime import datetime, timedelta, timezone

CST = timezone(timedelta(hours=8))


def cst_from_iso(value):
    """UTC ISO 字符串 → 东八区展示串；解析失败时原样返回。"""
    try:
        return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(CST).strftime('%Y-%m-%d %H:%M:%S')
    except (ValueError, AttributeError):
        return value or '-'


def cst_from_ms(ms):
    """epoch 毫秒 → 东八区展示串。"""
    if not ms:
        return '-'
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).astimezone(CST).strftime('%Y-%m-%d %H:%M:%S')


def short(value, length=8):
    """截断长标识用于列表展示。"""
    if value is None:
        return '-'
    return str(value)[:length]


def format_size(size):
    """字节数的可读形式。"""
    size = size or 0
    if size >= 1024 * 1024:
        return f'{size / (1024 * 1024):.1f} MB'
    if size >= 1024:
        return f'{size / 1024:.0f} KB'
    return f'{size} B'
