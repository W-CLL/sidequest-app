"""记录与删除墓碑：entries / entry_tombstones 表。"""
from django.db import models

from .accounts import User


class Entry(models.Model):
    # 实际主键为 (user_id, id)；此处以 id 作为单列主键以便后台导航，
    # 同一记录 ID 跨账号复用的极端情况在本地调试中可忽略。
    id = models.TextField(primary_key=True)
    user = models.ForeignKey(
        User,
        on_delete=models.DO_NOTHING,
        db_column='user_id',
        related_name='entries',
        db_constraint=False,
        verbose_name='账号',
    )
    quest_id = models.TextField(verbose_name='活动 ID')
    quest_title = models.TextField(verbose_name='活动标题')
    text = models.TextField(verbose_name='记录内容', help_text='直接修改数据库文本，不会推进 revision；仅本地调试用。')
    created_at = models.TextField(verbose_name='创建时间（UTC ISO）')
    updated_at = models.TextField(verbose_name='更新时间（UTC ISO）')
    revision = models.IntegerField(verbose_name='修订号')
    creation_hash = models.TextField(null=True, verbose_name='创建哈希')

    class Meta:
        managed = False
        db_table = 'entries'
        verbose_name = '记录'
        verbose_name_plural = '记录'

    def __str__(self):
        return f'{self.quest_title} · {self.text[:20]}'


class EntryTombstone(models.Model):
    """已删除记录的墓碑：用于排查「删除后又出现」或同步未收敛。"""

    # 同 Entry：实际主键为 (user_id, id)。
    id = models.TextField(primary_key=True)
    user = models.ForeignKey(
        User,
        on_delete=models.DO_NOTHING,
        db_column='user_id',
        related_name='entry_tombstones',
        db_constraint=False,
        verbose_name='账号',
    )
    creation_hash = models.TextField(null=True, verbose_name='创建哈希')
    deleted_at = models.TextField(verbose_name='删除时间（UTC ISO）')

    class Meta:
        managed = False
        db_table = 'entry_tombstones'
        verbose_name = '删除墓碑'
        verbose_name_plural = '删除墓碑'

    def __str__(self):
        return f'{self.user.nickname} 删除的 {self.id[:8]}'
