"""版本分发（APK 文件存储，本模型只是后台页面入口，不映射数据库表）。"""
from django.db import models


class ApkRelease(models.Model):
    """占位镜像：真实数据是服务端 apk 目录里的文件；与 Quest/ClientDiagnostic 相同的模式。

    'apk_release_stub' 表不存在，因此必须覆写 get_object 直接拒绝，
    避免默认视图查不存在的表抛 500。
    """

    class Meta:
        managed = False
        db_table = 'apk_release_stub'
        verbose_name = '版本分发'
        verbose_name_plural = '版本分发'
