"""目录备份：每次改动 catalog.json 前落盘一份，可列表 / 下载 / 恢复。

备份文件与后台数据同目录（server/admin/catalog-backups/，已 gitignore），
命名 catalog-<时间戳>[-序号]-<原因>.json，按名称即时间序；仅保留最近 KEEP 份。
"""
import json
import re
from datetime import datetime
from pathlib import Path

from django.conf import settings

from .errors import QuestSaveError

BACKUP_DIR = Path(settings.BASE_DIR) / 'catalog-backups'
KEEP = 50
NAME_PATTERN = re.compile(r'^catalog-\d{8}-\d{6}(?:-\d+)?(?:-[a-z-]+)?\.json$')
REASON_PATTERN = re.compile(r'^catalog-\d{8}-\d{6}(?:-\d+)?(?:-([a-z-]+))?\.json$')
REASON_LABELS = {
    'add': '新增任务',
    'edit': '编辑任务',
    'move': '调整顺序',
    'enable': '启用任务',
    'disable': '停用任务',
    'restore': '恢复备份',
    'manual': '手动备份',
}


def create_backup(payload_text, reason='edit'):
    """把改动前的目录原文写入备份；返回备份路径。写失败时抛 QuestSaveError（调用方中止保存）。"""
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    path = None
    for index in range(1000):
        suffix = f'-{index}' if index else ''
        candidate = BACKUP_DIR / f'catalog-{stamp}{suffix}-{reason}.json'
        if not candidate.exists():
            path = candidate
            break
    if path is None:
        raise QuestSaveError('无法分配备份文件名（同秒备份过多）。')
    try:
        path.write_text(payload_text, encoding='utf-8')
    except OSError as exc:
        raise QuestSaveError(f'写入备份失败，已中止本次保存：{exc}') from exc
    _prune()
    return path


def resolve_backup(name):
    """把备份名解析为目录内的真实文件路径；非法名称/越界/不存在 → QuestSaveError。"""
    if not NAME_PATTERN.fullmatch(name or ''):
        raise QuestSaveError('备份文件名不合法。')
    root = BACKUP_DIR.resolve()
    path = (BACKUP_DIR / name).resolve()
    if path.parent != root or not path.is_file():
        raise QuestSaveError('备份文件不存在。')
    return path


def read_backup(name):
    path = resolve_backup(name)
    try:
        return path.read_text(encoding='utf-8')
    except OSError as exc:
        raise QuestSaveError(f'读取备份失败：{exc}') from exc


def list_backups():
    """按时间倒序列出备份概要（解析失败的文件也列出，便于人工处理）。"""
    if not BACKUP_DIR.is_dir():
        return []
    items = []
    for path in sorted(BACKUP_DIR.glob('catalog-*.json'), reverse=True):
        stat = path.stat()
        try:
            data = json.loads(path.read_text(encoding='utf-8'))
        except (OSError, json.JSONDecodeError):
            count = None
            disabled = None
        else:
            count = len(data) if isinstance(data, list) else None
            disabled = (
                sum(1 for quest in data if isinstance(quest, dict) and quest.get('enabled') is False)
                if isinstance(data, list) else None
            )
        match = REASON_PATTERN.fullmatch(path.name)
        reason = match.group(1) if match and match.group(1) else 'manual'
        items.append({
            'name': path.name,
            'reason': reason,
            'reason_label': REASON_LABELS.get(reason, reason),
            'at': datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M:%S'),
            'count': count,
            'disabled': disabled,
            'size': stat.st_size,
        })
    return items


def _prune():
    backups = sorted(BACKUP_DIR.glob('catalog-*.json'))
    for old in backups[:-KEEP]:
        try:
            old.unlink()
        except OSError:
            pass
