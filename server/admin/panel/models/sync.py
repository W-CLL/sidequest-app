"""同步协议排查：sync_branches / mutation_receipts / command_receipts 表。

回执（receipt）用于保证客户端「不确定的请求结果」可以安全重放：
- mutation_receipts：按 (user_id, id) 记录某次变更请求的结果；
- command_receipts：按 (user_id, id) 记录分支上某条指令的回执。
排查口径：客户端卡在同步 / 重放不一致时，对照这里的 request_hash 与 result/receipt。
"""
from django.db import models

from .accounts import User


class SyncBranch(models.Model):
    id = models.TextField(primary_key=True, verbose_name='分支 ID')
    user = models.ForeignKey(
        User,
        on_delete=models.DO_NOTHING,
        db_column='user_id',
        related_name='sync_branches',
        db_constraint=False,
        verbose_name='账号',
    )
    base_revision = models.IntegerField(verbose_name='基础版本')
    last_revision = models.IntegerField(verbose_name='上次应用版本')
    mode = models.TextField(verbose_name='模式')

    class Meta:
        managed = False
        db_table = 'sync_branches'
        verbose_name = '同步分支'
        verbose_name_plural = '同步分支'


class MutationReceipt(models.Model):
    # 同 Entry：实际主键为 (user_id, id)。
    id = models.TextField(primary_key=True)
    user = models.ForeignKey(
        User,
        on_delete=models.DO_NOTHING,
        db_column='user_id',
        related_name='mutation_receipts',
        db_constraint=False,
        verbose_name='账号',
    )
    request_hash = models.TextField(verbose_name='请求哈希')
    result = models.TextField(verbose_name='处理结果(JSON)')

    class Meta:
        managed = False
        db_table = 'mutation_receipts'
        verbose_name = '同步回执'
        verbose_name_plural = '同步回执'

    def __str__(self):
        return f'回执 {self.id[:8]}'


class CommandReceipt(models.Model):
    # 同 Entry：实际主键为 (user_id, id)。
    id = models.TextField(primary_key=True)
    user = models.ForeignKey(
        User,
        on_delete=models.DO_NOTHING,
        db_column='user_id',
        related_name='command_receipts',
        db_constraint=False,
        verbose_name='账号',
    )
    branch_id = models.TextField(verbose_name='分支 ID')
    request_hash = models.TextField(verbose_name='请求哈希')
    receipt = models.TextField(verbose_name='指令回执(JSON)')

    class Meta:
        managed = False
        db_table = 'command_receipts'
        verbose_name = '指令回执'
        verbose_name_plural = '指令回执'

    def __str__(self):
        return f'指令回执 {self.id[:8]}'
