"""探索任务目录的展示用模型（数据在 server/catalog.json，不落库）。"""
from django.db import models


class Quest(models.Model):
    """仅作为管理后台的挂载点：列表与新增/编辑均为自定义页面。

    此模型不查询、不写入；`db_table` 指向一个不存在的占位表——后台已覆写
    `get_object`，任何试图按主键取对象的默认视图（change/delete/history）
    会直接 403，而不是去查这张表。
    """

    id = models.TextField(primary_key=True, verbose_name='活动 ID')

    class Meta:
        managed = False
        db_table = 'quest_catalog_stub'
        verbose_name = '探索任务'
        verbose_name_plural = '探索任务'

    def __str__(self):
        return self.id
