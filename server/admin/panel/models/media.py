"""媒体与清理队列：media / media_bindings / media_cleanup 表。"""
from django.db import models

from .accounts import User


class Media(models.Model):
    id = models.TextField(primary_key=True)
    user = models.ForeignKey(
        User,
        on_delete=models.DO_NOTHING,
        db_column='user_id',
        related_name='media',
        db_constraint=False,
        verbose_name='账号',
    )
    client_upload_id = models.TextField(verbose_name='客户端上传 ID')
    kind = models.TextField(verbose_name='类型')
    status = models.TextField(verbose_name='状态')
    source_bytes = models.IntegerField(verbose_name='源文件字节')
    reserved_bytes = models.IntegerField(verbose_name='预留字节')
    byte_size = models.IntegerField(verbose_name='处理后字节')
    mime_type = models.TextField(verbose_name='MIME')
    duration_ms = models.IntegerField(null=True, verbose_name='时长(ms)')
    width = models.IntegerField(null=True, verbose_name='宽')
    height = models.IntegerField(null=True, verbose_name='高')
    content_name = models.TextField(null=True, verbose_name='内容文件名')
    thumbnail_name = models.TextField(null=True, verbose_name='缩略图文件名')
    error = models.TextField(null=True, verbose_name='错误')
    created_at = models.BigIntegerField(verbose_name='创建时间(epoch ms)')

    class Meta:
        managed = False
        db_table = 'media'
        verbose_name = '媒体'
        verbose_name_plural = '媒体'

    def __str__(self):
        return f'{self.kind}/{self.status} {self.id[:8]}'


class MediaBinding(models.Model):
    media = models.OneToOneField(
        Media,
        on_delete=models.DO_NOTHING,
        db_column='media_id',
        primary_key=True,
        related_name='bindings',
        db_constraint=False,
        verbose_name='媒体',
    )
    user = models.ForeignKey(
        User,
        on_delete=models.DO_NOTHING,
        db_column='user_id',
        related_name='media_bindings',
        db_constraint=False,
        verbose_name='账号',
    )
    target_kind = models.TextField(verbose_name='目标类型')
    target_id = models.TextField(verbose_name='目标 ID')
    position = models.IntegerField(verbose_name='排序')

    class Meta:
        managed = False
        db_table = 'media_bindings'
        verbose_name = '媒体绑定'
        verbose_name_plural = '媒体绑定'


class MediaCleanup(models.Model):
    """媒体清理队列：记录「删除失败待重试」的媒体。

    排查口径：attempts 持续增长 + last_error 非空 = 清理反复失败；
    正常情况队列应为空或短暂存在。
    """

    media_id = models.TextField(primary_key=True, verbose_name='媒体 ID')
    attempts = models.IntegerField(verbose_name='尝试次数')
    created_at = models.BigIntegerField(verbose_name='入队时间(epoch ms)')
    last_error = models.TextField(null=True, verbose_name='最近错误')

    class Meta:
        managed = False
        db_table = 'media_cleanup'
        verbose_name = '媒体清理队列'
        verbose_name_plural = '媒体清理队列'

    def __str__(self):
        return f'清理 {self.media_id[:8]}'
