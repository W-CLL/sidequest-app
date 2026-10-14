"""服务端元数据：server_metadata 表（key/value，如协议版本）。"""
from django.db import models


class ServerMetadata(models.Model):
    key = models.TextField(primary_key=True, verbose_name='键')
    value = models.TextField(verbose_name='值')

    class Meta:
        managed = False
        db_table = 'server_metadata'
        verbose_name = '服务端元数据'
        verbose_name_plural = '服务端元数据'

    def __str__(self):
        return self.key
