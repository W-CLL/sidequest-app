"""catalog.json 的读写、备份与回滚。

所有写操作走同一流程（mutate_catalog）：
  读取原文 → 内存中变换 → 内容无变化则直接返回
  → 备份原文 → 写盘 → 运行生成脚本（含完整校验与 Dart 再生成）
  → 失败则回滚原文并重新生成。
调用方只需提供变换函数；`QuestSaveError` 消息可直接展示给操作者。
"""
import json
import shutil
import subprocess
from pathlib import Path

from django.conf import settings

from . import backups
from .constants import ITEM_FIELDS, ORIGINAL_COUNT
from .errors import QuestSaveError

CATALOG_PATH = Path(settings.REPO_DIR) / 'server' / 'catalog.json'
GENERATOR_SCRIPT = 'scripts/generate-catalog.mjs'


def load_catalog():
    return json.loads(CATALOG_PATH.read_text(encoding='utf-8'))


def catalog_text():
    """目录文件的原文（手动备份等场景使用）。"""
    return CATALOG_PATH.read_text(encoding='utf-8')


def run_generator():
    node = shutil.which('node')
    if not node:
        return False, '未找到 node（PATH 中没有 node 可执行文件），无法重新生成客户端目录。'
    try:
        proc = subprocess.run(
            [node, GENERATOR_SCRIPT],
            cwd=str(settings.REPO_DIR),
            capture_output=True,
            text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        return False, '生成脚本运行超时。'
    output = ((proc.stdout or '') + (proc.stderr or '')).strip()
    return proc.returncode == 0, output or f'生成脚本退出码 {proc.returncode}'


def project_item(quest):
    """把表单产物投影为目录条目：必填字段 + （仅停用时）enabled。"""
    item = {key: quest[key] for key in ITEM_FIELDS}
    if quest.get('enabled') is False:
        item['enabled'] = False
    return item


def _serialize(catalog, original_text):
    newline = '\r\n' if original_text.endswith('\r\n') else '\n'
    return json.dumps(catalog, ensure_ascii=False, indent=2).replace('\n', newline) + newline


def mutate_catalog(mutator, reason):
    """统一写流程；返回是否发生实际变化（无变化不写盘、不备份、不重生成）。"""
    original = CATALOG_PATH.read_text(encoding='utf-8')
    catalog = json.loads(original)
    mutator(catalog)  # 校验错误（QuestSaveError）在写盘前抛出，无需回滚
    payload = _serialize(catalog, original)
    if payload == original:
        return False
    backups.create_backup(original, reason)
    CATALOG_PATH.write_text(payload, encoding='utf-8')

    ok, output = run_generator()
    if not ok:
        CATALOG_PATH.write_text(original, encoding='utf-8')
        run_generator()  # 生成文件回到与回滚后的目录一致
        raise QuestSaveError(output)
    return True


def _find_index(catalog, quest_id):
    return next((i for i, item in enumerate(catalog) if item['id'] == quest_id), None)


def append_quest(quest):
    """追加新任务到目录末尾并重新生成客户端目录。"""
    def mutate(catalog):
        if _find_index(catalog, quest['id']) is not None:
            raise QuestSaveError(f"活动 ID「{quest['id']}」已存在。")
        catalog.append(project_item(quest))
    mutate_catalog(mutate, 'add')
    return quest['id']


def update_quest(quest_id, quest):
    """按 ID 原位替换任务内容（位置不变）。"""
    def mutate(catalog):
        index = _find_index(catalog, quest_id)
        if index is None:
            raise QuestSaveError(f'找不到活动「{quest_id}」。')
        replacement = project_item(quest)
        replacement['id'] = quest_id  # 活动 ID 不允许修改
        catalog[index] = replacement
    mutate_catalog(mutate, 'edit')
    return quest_id


def move_quest(quest_id, direction):
    """在可调整范围内（原始 16 条之后）上移/下移一条任务。"""
    if direction not in ('up', 'down'):
        raise QuestSaveError('未知的移动方向。')

    def mutate(catalog):
        index = _find_index(catalog, quest_id)
        if index is None:
            raise QuestSaveError(f'找不到活动「{quest_id}」。')
        if index < ORIGINAL_COUNT:
            raise QuestSaveError('原始 16 条任务的顺序被生成脚本锁定，不能调整。')
        target = index - 1 if direction == 'up' else index + 1
        if target < ORIGINAL_COUNT or target >= len(catalog):
            raise QuestSaveError('已经到达可调整范围的边界。')
        catalog[index], catalog[target] = catalog[target], catalog[index]
    mutate_catalog(mutate, 'move')
    return quest_id


def set_enabled(quest_id, enabled):
    """启用/停用一条任务；停用写入 enabled=False，启用则移除该键。"""
    def mutate(catalog):
        item = next((q for q in catalog if q['id'] == quest_id), None)
        if item is None:
            raise QuestSaveError(f'找不到活动「{quest_id}」。')
        if enabled:
            item.pop('enabled', None)
        else:
            item['enabled'] = False
    mutate_catalog(mutate, 'enable' if enabled else 'disable')
    return quest_id


def restore_backup(name):
    """用备份整体替换目录；生成脚本校验失败会自动回滚。返回是否发生实际变化。"""
    text = backups.read_backup(name)
    try:
        restored = json.loads(text)
    except json.JSONDecodeError as exc:
        raise QuestSaveError(f'备份内容不是合法 JSON：{exc}') from exc
    if not isinstance(restored, list):
        raise QuestSaveError('备份内容不是任务列表（JSON 数组）。')

    def mutate(catalog):
        catalog.clear()
        catalog.extend(restored)
    return mutate_catalog(mutate, 'restore')
