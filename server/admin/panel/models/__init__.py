"""现有 SQLite 表的只读镜像模型（全部 managed=False，绝不建表/改表）。

按业务域拆分到子模块，统一在本模块重新导出：外部 `from panel.models import ...`
的用法保持不变；新增表时只在对应子模块添加镜像并为后台注册页面。
"""
from .accounts import LoginSession, User
from .catalog import Quest
from .diagnostics import ClientDiagnostic
from .downloads import DownloadEvent
from .media import Media, MediaBinding, MediaCleanup
from .progress import QuestState
from .records import Entry, EntryTombstone
from .releases import ApkRelease
from .runtime import ServerMetadata
from .sync import CommandReceipt, MutationReceipt, SyncBranch

__all__ = [
    'User',
    'LoginSession',
    'Entry',
    'EntryTombstone',
    'Media',
    'MediaBinding',
    'MediaCleanup',
    'QuestState',
    'SyncBranch',
    'MutationReceipt',
    'CommandReceipt',
    'ServerMetadata',
    'Quest',
    'ClientDiagnostic',
    'ApkRelease',
    'DownloadEvent',
]
