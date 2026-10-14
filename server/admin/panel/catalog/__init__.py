"""探索任务目录的后端能力（读写、备份、表单）。

- store：catalog.json 的唯一读写入口（备份 + 生成 + 回滚一体化）
- backups：备份文件的落盘、列表、解析、清理
- forms / constants：表单与共享常量
- errors：QuestSaveError
"""
from . import backups
from .constants import (
    CATEGORIES,
    ITEM_FIELDS,
    OPTIONAL_ITEM_FIELDS,
    ORIGINAL_COUNT,
    PREFERENCES,
    ROLE_LABELS,
)
from .errors import QuestSaveError
from .forms import QuestForm, validate_text
from .store import (
    CATALOG_PATH,
    append_quest,
    catalog_text,
    load_catalog,
    move_quest,
    restore_backup,
    run_generator,
    set_enabled,
    update_quest,
)

__all__ = [
    'backups',
    'CATEGORIES',
    'PREFERENCES',
    'ROLE_LABELS',
    'ITEM_FIELDS',
    'OPTIONAL_ITEM_FIELDS',
    'ORIGINAL_COUNT',
    'QuestSaveError',
    'QuestForm',
    'CATALOG_PATH',
    'append_quest',
    'catalog_text',
    'load_catalog',
    'move_quest',
    'restore_backup',
    'run_generator',
    'set_enabled',
    'update_quest',
    'validate_text',
]
