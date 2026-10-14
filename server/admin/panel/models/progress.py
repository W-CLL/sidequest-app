"""活动进度：quest_state 表（每个账号一行，修数据用，允许编辑）。"""
from django.db import models

from .accounts import User


class QuestState(models.Model):
    user = models.OneToOneField(
        User,
        on_delete=models.DO_NOTHING,
        db_column='user_id',
        primary_key=True,
        related_name='quest_state',
        db_constraint=False,
        verbose_name='账号',
    )
    active_quest_id = models.TextField(null=True, verbose_name='当前活动 ID')
    recommended_quest_id = models.TextField(verbose_name='推荐活动 ID')
    replaced_on = models.TextField(null=True, verbose_name='更换日期')
    draft = models.TextField(verbose_name='云端草稿')
    day = models.TextField(verbose_name='自然日')
    can_request_next = models.IntegerField(verbose_name='可换活动(1/0)')
    progress_revision = models.IntegerField(verbose_name='进度版本')
    recommendation_history = models.TextField(verbose_name='推荐历史(JSON)')

    class Meta:
        managed = False
        db_table = 'quest_state'
        verbose_name = '活动进度'
        verbose_name_plural = '活动进度'

    def __str__(self):
        return f'{self.user.nickname} 的进度'
